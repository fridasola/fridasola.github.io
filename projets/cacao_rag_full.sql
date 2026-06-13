-- Suppression des tables si elles existent pour repartir à neuf
DROP TABLE IF EXISTS dbo.CacaoProducts;
DROP TABLE IF EXISTS dbo.ProductBenefits;
GO

-- 1. Création de la table des Bienfaits / Rituels
CREATE TABLE dbo.ProductBenefits (
    BenefitID INT IDENTITY(1,1) PRIMARY KEY,
    BenefitName VARCHAR(100) NOT NULL,
    TargetMood VARCHAR(100) NOT NULL
);

-- 2. Création de la table des Produits Cacao avec la colonne Vectorielle
CREATE TABLE dbo.CacaoProducts (
    ProductID INT IDENTITY(1,1) PRIMARY KEY,
    ProductName NVARCHAR(150) NOT NULL,
    OriginCountry NVARCHAR(100) NOT NULL,
    Description NVARCHAR(MAX) NOT NULL,
    Price DECIMAL(5,2) NOT NULL,
    BenefitID INT FOREIGN KEY REFERENCES dbo.ProductBenefits(BenefitID),
    CacaoVector VECTOR(1536) NULL -- 1536 dimensions pour correspondre au modèle text-embedding-3-small
);
GO

-- 3. Insertion du jeu de données (Le catalogue holistique)
INSERT INTO dbo.ProductBenefits (BenefitName, TargetMood) VALUES 
('Rituel du Matin &amp; Énergie', 'Concentration, Vitalité sans stress'),
('Rituel du Soir &amp; Détente', 'Relaxation, Sommeil profond, Anti-anxiété'),
('Ancrage &amp; Méditation Chamanique', 'Pleine conscience, Connexion spirituelle');

INSERT INTO dbo.CacaoProducts (ProductName, OriginCountry, Description, Price, BenefitID) VALUES
(N'" Élixir Cacao Sacré"', N'Pérou', N'Un cacao de variété Criollo, idéal pour l''ancrage spirituel lors des méditations. Offre des notes terreuses et une douceur qui apaise l''esprit sans caféine agressive.', 29.99, 3),
(N'Aurore Énergisante', N'Équateur', N'Alternative douce et parfaite au café pour le matin. Enrichi aux épices douces, il stimule la concentration et réveille le corps en douceur pour un rituel sans stress.', 24.50, 1),
(N'Sérénité du Soir', N'Madagascar', N'Cacao extra-fin aux notes florales et de vanille. Conçu spécifiquement pour le rituel de fin de journée, il aide à relâcher l''anxiété et prépare à un sommeil profond.', 27.00, 2);
GO

-- 1. Création de la clé maîtresse de chiffrement de la base (si inexistante)
IF NOT EXISTS (SELECT * FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
BEGIN
    CREATE MASTER KEY ENCRYPTION BY PASSWORD 'TonMotDePasseFortEtSecurise123!';
END;
GO

-- 2. Création de l'identifiant lié à l'Identité Managée du serveur SQL
-- Note : Le resourceid est l'audience fixe mondiale d'Azure Cognitive Services (ne pas modifier)
CREATE DATABASE SCOPED CREDENTIAL [https://cacaomood-openai.openai.azure.com]
WITH IDENTITY = 'Managed Identity', 
SECRET = '{"resourceid": "https://cognitiveservices.azure.com"}';
GO

-- 3. Déclaration du modèle externe pour la génération d'embeddings
CREATE EXTERNAL MODEL my_embedding_model
WITH (
    LOCATION = 'https://cacaomood-openai.openai.azure.com/openai/deployments/text-embedding-3-small/embeddings?api-version=2024-10-21',
    API_FORMAT = 'Azure OpenAI',
    MODEL_TYPE = EMBEDDINGS,
    MODEL = 'text-embedding-3-small',
    CREDENTIAL = [https://cacaomood-openai.openai.azure.com]
);
GO

-- Vectorisation batch
DECLARE @batchSize INT = 30; -- Taille des lots de traitement
DECLARE @rowsUpdated INT = 1;
DECLARE @retryCount INT;
DECLARE @maxRetries INT = 3;

WHILE @rowsUpdated &gt; 0
BEGIN
    SET @retryCount = 0;
    
    RETRY_BATCH:
    BEGIN TRY
        -- Mise à jour sémantique en combinant les colonnes textuelles clés
        UPDATE TOP (@batchSize) p
        SET p.CacaoVector = AI_GENERATE_EMBEDDINGS(
            p.ProductName + ' | Origine: ' + p.OriginCountry + ' | Bienfaits: ' + b.BenefitName + ' | ' + p.Description
            USE MODEL my_embedding_model
        )
        FROM dbo.CacaoProducts p
        INNER JOIN dbo.ProductBenefits b ON p.BenefitID = b.BenefitID
        WHERE p.CacaoVector IS NULL; -- Ne traite que les lignes non vectorisées
        
        SET @rowsUpdated = @@ROWCOUNT;

        -- Courte pause pour respecter les limites de l'API Azure OpenAI
        IF @rowsUpdated &gt; 0
        BEGIN
            WAITFOR DELAY '00:00:02';
        END
    END TRY
    BEGIN CATCH
        SET @retryCount += 1;
        IF @retryCount &lt;= @maxRetries
        BEGIN
            PRINT 'Limite de requêtes atteinte (Rate limited). Réessai dans 5 secondes... Tentative ' + CAST(@retryCount AS VARCHAR(2));
            WAITFOR DELAY '00:00:05';
            GOTO RETRY_BATCH;
        END
        ELSE
        BEGIN
            THROW; -- Lève l'exception si le problème persiste après 3 tentatives
        END
    END CATCH
END;
GO

-- Vérification de la réussite de l'opération
SELECT COUNT(*) AS TotalCacaos, COUNT(CacaoVector) AS CacaosVectorises 
FROM dbo.CacaoProducts;
GO

-- Activation DiskANN
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO

ALTER DATABASE SCOPED CONFIGURATION SET ALLOW_STALE_VECTOR_INDEX = ON;
GO

CREATE VECTOR INDEX IX_CacaoProducts_CacaoVector
ON dbo.CacaoProducts(CacaoVector)
WITH (METRIC = 'cosine', TYPE = 'DISKANN');
GO

-- Procédure AskCacaoQuestion
CREATE OR ALTER PROCEDURE dbo.AskCacaoQuestion
    @Question NVARCHAR(1000),
    @Answer NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @questionVector VECTOR(1536);
    DECLARE @context NVARCHAR(MAX);
    DECLARE @payload NVARCHAR(MAX);
    DECLARE @response NVARCHAR(MAX);
    DECLARE @returnValue INT;
    
    -- ÉTAPE 1 : Vectorisation instantanée de la question de la cliente
    SELECT @questionVector = AI_GENERATE_EMBEDDINGS(@Question USE MODEL my_embedding_model);
    
    -- ÉTAPE 2 : Récupération sémantique des 3 meilleurs cacaos via l'index DiskANN (R)
    SET @context = (
        SELECT TOP 3 
            p.ProductName AS [Cacao.Name], 
            p.OriginCountry AS [Cacao.Origin], 
            p.Price AS [Cacao.Price],
            b.BenefitName AS [Cacao.Ritual],
            p.Description AS [Cacao.Description]
        FROM VECTOR_SEARCH(
            TABLE = dbo.CacaoProducts AS p,
            COLUMN = CacaoVector,
            SIMILAR_TO = @questionVector,
            METRIC = 'cosine',
            TOP_N = 3
        ) AS vs
        INNER JOIN dbo.ProductBenefits b ON p.BenefitID = b.BenefitID
        FOR JSON PATH
    );
    
    -- Sécurité : Si aucun produit n'est retourné par l'index
    IF @context IS NULL
    BEGIN
        SET @Answer = N'Désolé, je n''ai trouvé aucun cacao correspondant à votre rituel actuel dans notre catalogue. Pouvez-vous préciser votre recherche ?';
        RETURN;
    END;
    
    -- ÉTAPE 3 : Augmentation du prompt (A) - Définition des règles d'ancrage strictes (Grounding)
    SET @payload = JSON_OBJECT(
        'messages': JSON_ARRAY(
            JSON_OBJECT(
                'role': 'system', 
                'content': N'Tu es l''assistante holistique experte pour la marque CacaoMood. Directives absolues :\n1. Réponds aux questions des clientes en utilisant UNIQUEMENT les données du catalogue fournies.\n2. Si les données fournies ne permettent pas de répondre, dis gentiment que tu dois valider auprès de l''équipe.\n3. Ne crée JAMAIS de bienfaits, d''origines ou de prix imaginaires.\n4. Garde un ton doux, chaleureux, axé sur le bien-être et réponds en moins de 150 mots.'
            ),
            JSON_OBJECT(
                'role': 'user', 
                'content': 'Catalogue disponible au format JSON : ' + @context + CHAR(10) + CHAR(10) + 'Question de la cliente : ' + @Question
            )
        ),
        'max_tokens': 600,
        'temperature': 0.3 -- Température basse pour éliminer la créativité et forcer la fidélité des prix et stocks
    );
    
    -- ÉTAPE 4 : Envoi HTTPS direct au modèle Azure OpenAI (G)
    EXECUTE @returnValue = sp_invoke_external_rest_endpoint
        @url = N'https://cacaomood-openai.openai.azure.com/openai/deployments/gpt-5.4-mini/chat/completions?api-version=2024-10-21',
        @method = 'POST',
        @payload = @payload,
        @credential = [https://cacaomood-openai.openai.azure.com],
        @retry_count = 3, -- Gestion automatique des coupures réseau transitoires
        @response = @response OUTPUT;
    
    -- ÉTAPE 5 : Extraction de la réponse rédigée ou traitement des erreurs d'infrastructure
    IF @returnValue = 0
    BEGIN
        -- Extraction propre du contenu textuel du message généré par l'assistant
        SET @Answer = JSON_VALUE(@response, '$.result.choices[0].message.content');
    END
    ELSE IF @returnValue = 429
    BEGIN
        SET @Answer = N'Notre guide holistique subit une forte affluence. Veuillez patienter quelques instants avant de formuler votre prochain rituel.';
    END
    ELSE
    BEGIN
        SET @Answer = N'Une connexion réseau instable empêche de joindre l''assistant IA. Statut technique de l''erreur : HTTP ' + CAST(@returnValue AS NVARCHAR(10));
    END
END;
GO

-- Tests
DECLARE @reponseApplication NVARCHAR(MAX);

EXEC dbo.AskCacaoQuestion 
    @Question = N'Je cherche une alternative douce au café pour mon rituel du matin sans stress',
    @Answer = @reponseApplication OUTPUT;

SELECT @reponseApplication AS [Assistant_CacaoMood_Output];
GO

DECLARE @reponseApplication2 NVARCHAR(MAX);

EXEC dbo.AskCacaoQuestion 
    @Question = N'Quel mélange me conseillez-vous pour décompresser le soir avant de dormir car je suis très anxieuse ?',
    @Answer = @reponseApplication2 OUTPUT;

SELECT @reponseApplication2 AS [Assistant_CacaoMood_Output];
GO
