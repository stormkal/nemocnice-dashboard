# nemocnice-dashboard

Pracovní dashboard (Nemocnice Vrchlabí + Kalrox) na druhý monitor.

## Soubory na PC v práci (všechny do jedné složky)
- `dashboard.html` – otevřít v Chrome/Edge, klávesa **F** = celá obrazovka
- `ping-monitor.ps1` + `start-ping.cmd` – ping interních serverů každých 15 s → zapisuje `ping.js`
- `stop-ping.cmd` – zastaví ping monitor

Automatické spuštění po přihlášení: Win+R → `shell:startup` → vložit zástupce na `start-ping.cmd`.

## Stav ČSSZ / eZdraví / eRecept
GitHub Action (`.github/workflows/status.yml`) každých ~10 min načte stavové stránky (`scrape.mjs`)
a výsledek uloží do větve `data` (`status.json`). Dashboard ho čte přes raw.githubusercontent.com / jsDelivr.
