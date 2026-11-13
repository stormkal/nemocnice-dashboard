# nemocnice-dashboard

Pracovní dashboard (Nemocnice Vrchlabí + Kalrox) na druhý monitor.

## Použití
Stačí otevřít `dashboard.html` v Chrome/Edge, klávesa **F** = celá obrazovka.

## Stav ČSSZ / eZdraví / eRecept
GitHub Action (`.github/workflows/status.yml`) každých ~10 min načte stavové stránky (`scrape.mjs`)
a výsledek uloží do větve `data` (`status.json`). Dashboard ho čte přes raw.githubusercontent.com / jsDelivr.
