# Claude Code prova Nomorediet sull'iPhone

Questo è il kit "Claude can control your old iPhone" (Mr. Paid Social), adattato a Nomorediet.
Colleghi l'iPhone con un cavo dati al computer dove usi Claude Code. Claude apre l'app, tocca i
pulsanti per nome (gli id sono nel file `.claude/skills/iphone-control/SKILL.md`) e fa uno
screenshot dopo ogni passo. Non salva pasti, non cancella niente e non tocca Condividi, Invia o
Elimina senza il tuo sì.

| File | Cosa fa |
|---|---|
| `wda.py` | i comandi: `devices`, `up`, `apps`, `launch`, `els`, `tap-el`, `type`, `shot`, `home`, `down` |
| `build-wda.sh` | su Mac: compila e firma WebDriverAgent con Xcode |
| `../../.claude/skills/iphone-control/SKILL.md` | le regole e i passi del test di Nomorediet per Claude Code |

## Sull'iPhone (una volta)
1. Impostazioni > Privacy e sicurezza > Modalità sviluppatore > attiva (il telefono si riavvia).
2. Collegalo con un cavo **dati**, sbloccalo e tocca **Autorizza** (Trust).
3. Impostazioni > Schermo e luminosità > Blocco automatico > Mai. Risparmio energetico spento.

## Strada A: con un Mac (quella provata dall'autore della guida)
```
python3 -m pip install -U pymobiledevice3
git clone https://github.com/appium/WebDriverAgent ~/Developer/WebDriverAgent
APPLE_TEAM_ID=<il tuo team id> WDA_BUNDLE_ID=com.tuonome.WebDriverAgentRunner scripts/iphone/build-wda.sh
export WDA_BUNDLE_ID=com.tuonome.WebDriverAgentRunner
python3 scripts/iphone/wda.py devices
python3 scripts/iphone/wda.py up
```

## Strada B: con il PC Windows e SideStore (sperimentale, non ancora provata)
1. Installa Python 3 e poi `python -m pip install -U pymobiledevice3`. Servono anche i driver Apple:
   installa iTunes o "Apple Devices" dal Microsoft Store.
2. Scarica `WebDriverAgent.ipa` dalla release "tools" di nomorediet-updates e installalo con
   SideStore, come Nomorediet. Con un Apple ID gratuito SideStore tiene al massimo 3 app attive.
3. Su iOS 17 e successivi i servizi sviluppatore passano da un tunnel. Aprilo in un terminale
   **come amministratore** e lascialo aperto: `pymobiledevice3 remote tunneld`.
4. In un altro terminale, nella cartella del repo: `python scripts\iphone\wda.py devices`, poi `up`.
   `up` trova WebDriverAgent da solo anche se SideStore gli ha cambiato il bundle id.

Se `up` non parte, il messaggio dice quale pezzo manca (cavo, Autorizza, immagine sviluppatore,
WebDriverAgent). Puoi incollarlo a Claude.

## Poi
Apri Claude Code nella cartella del repo e scrivi per esempio: "L'iPhone è collegato: prova
Nomorediet, aggiungi a parole 80 g di pasta al pomodoro ma fermati prima di salvare, poi avvia il
timer di recupero e mostrami gli screenshot."
