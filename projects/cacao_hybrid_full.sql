-- CREATE TABLE example
CREATE TABLE dbo.CacaoProducts
(
    ProductID INT PRIMARY KEY,              -- Clé primaire stricte (Requise pour l'indexation DiskANN)
    ProductName NVARCHAR(150) NOT NULL,     -- ex: 'Élixir Cacao Sacré - Rituel du Matin'
    OriginCountry NVARCHAR(100) NOT NULL,   -- ex: 'Equateur'
    BenefitType NVARCHAR(100) NOT NULL,     -- ex: 'Énergie', 'Relaxation', 'Focus'
    Description NVARCHAR(MAX) NOT NULL,     -- ex: 'Alternative idéale au café. Énergie durable, sans palpitation...'
    CacaoVector VECTOR(1536) NOT NULL       -- Embeddings sémantiques de la fiche produit
);

-- Example hybrid RRF query
DECLARE @userInputText NVARCHAR(1000) = 'remplacer mon café du matin sans stress et avec de la douceur';
DECLARE @userQueryVector VECTOR(1536) = '[0.012, -0.043, ...]'; -- Généré via l'API d'embeddings
DECLARE @rrfK INT = 60;
DECLARE @topN INT = 50;

WITH keyword_search AS (
    SELECT TOP(@topN) p.ProductID,
        RANK() OVER (ORDER BY ftt.[RANK] DESC) AS keyword_rank
    FROM dbo.CacaoProducts p
    INNER JOIN FREETEXTTABLE(dbo.CacaoProducts, Description, @userInputText) AS ftt 
        ON p.ProductID = ftt.[KEY]
),
vector_search AS (
    SELECT TOP(@topN) t.ProductID,
        RANK() OVER (ORDER BY s.distance) AS vector_rank
    FROM VECTOR_SEARCH(
        TABLE = dbo.CacaoProducts AS t,
        COLUMN = CacaoVector,
        SIMILAR_TO = @userQueryVector,
        METRIC = 'cosine',
        TOP_N = @topN -- Stratégie de sur-échantillonnage
    ) AS s
),
combined AS (
    SELECT TOP(10)
        COALESCE(ks.ProductID, vs.ProductID) AS ProductID,
        COALESCE(1.0 / (@rrfK + ks.keyword_rank), 0.0) +
        COALESCE(1.0 / (@rrfK + vs.vector_rank), 0.0) AS rrf_score
    FROM keyword_search ks
    FULL OUTER JOIN vector_search vs ON ks.ProductID = vs.ProductID
)
SELECT p.ProductName, p.OriginCountry, p.BenefitType, c.rrf_score
FROM combined c
INNER JOIN dbo.CacaoProducts p ON c.ProductID = p.ProductID
WHERE p.BenefitType = 'Énergie' -- Post-filtrage sécurisé grâce à l'oversampling
ORDER BY c.rrf_score DESC;
