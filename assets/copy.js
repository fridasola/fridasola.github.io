document.addEventListener('DOMContentLoaded', function(){
  const buttons = document.querySelectorAll('.copy-btn');
  buttons.forEach(btn => {
    btn.addEventListener('click', async () => {
      const targetId = btn.getAttribute('data-target');
      const el = document.getElementById(targetId);
      if(!el) return;
      const text = el.innerText || el.textContent;
      try{
        await navigator.clipboard.writeText(text);
        const original = btn.innerText;
        btn.innerText = 'Copié !';
        setTimeout(()=> btn.innerText = original, 1500);
      }catch(e){
        const original = btn.innerText;
        btn.innerText = 'Erreur';
        setTimeout(()=> btn.innerText = original, 1500);
      }
    });
  });
});