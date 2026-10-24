# Nomorediet — Novità

## 4.13.3
- GLM "limite raggiunto": se un modello gratuito non è disponibile per il tuo account (codice 1113) l'app passa subito al successivo (glm-4.7-flash, glm-4.5-flash, glm-4-flash) invece di arrendersi; il messaggio dice quale modello e il codice di Z.ai.
- Una chiave accettata ma al limite resta collegata: non serve reinserirla.

## 4.13.2
- GLM: le chiavi create su bigmodel.cn (la piattaforma cinese di Zhipu) ora funzionano come quelle di z.ai: l'app prova entrambi i server e ricorda quello giusto.
- Se la chiave viene rifiutata, il messaggio riporta la risposta esatta del server, così si capisce se è copiata a metà o revocata.

## 4.13.1
- Widget: con SideStore (e Impactor) il gruppo condiviso tra app e widget si chiama con il codice del tuo account; ora l'app lo trova e il widget riceve di nuovo calorie e proteine.
- Aggiornamento del database alimenti: un prodotto con dati strani non blocca più tutto l'aggiornamento, e se Open Food Facts risponde con un errore il pannello di debug dice quale.

## 4.13
- Le tue schede: Giorno 1 panca piana manubri presa neutra, lat machine presa neutra, croci ai cavi, row singolo al cavo seduto, estensioni dietro la nuca al cavo basso, curl su panca inclinata. Giorno 2 leg press 45°, leg curl seduto, leg extension, leg curl singolo con ginocchio appoggiato, adductor e abductor. Giorno 3 chest press, pulldown al cavo alto, alzate laterali al cavo, row singolo ai cavi da terra, lat singola al cavo alto, estensioni dietro la nuca, face pull, curl al cavo singolo. Giorno 4 stacco rumeno con manubri, leg press 45° singola piedi alti, leg curl seduto e singolo, leg extension, abductor.
- Mai più squat, affondi, hip thrust, calf raise e addominali: nelle schede del Calendario vengono sostituiti (affondi → leg press 45° singola, rematore con manubrio → row singolo al cavo seduto, pulley basso → pulldown al cavo alto, croci con manubri → croci ai cavi) o tolti, e non compaiono in "Cambia esercizio", dove le tue varianti preferite sono in cima.
- Nuovo motore AI gratuito: GLM di Z.ai (glm-4.7-flash per testo e voce, glm-4.6v-flash per le foto). In alternativa DeepSeek (costa pochi centesimi, solo testo). Profilo → Analisi AI → "Accedi a GLM e collega la chiave".
- Calorie più affidabili: il fabbisogno calcolato dal diario non conta i giorni segnati solo in parte e resta vicino alla stima di partenza (tra −20% e +25%), così un pranzo dimenticato non ti abbassa le calorie.
- Ricerca nel database: prima gli alimenti che si chiamano come quello che cerchi ("riso" → riso, non gallette o "sorrisi"), poi i generici prima delle marche.

## 4.12.4
- Riconoscimento semplice più preciso: "200 g di riso" diventa riso cotto, non gallette di riso (cottura e "bianco/intero" non contano, e vince l'alimento il cui nome inizia con quello che hai scritto).
- "Cosa hai mangiato?": se l'AI non risponde (per esempio il modello di Apple non riesce), il pasto viene comunque riconosciuto con l'analisi semplice invece di non aggiungere niente.
- Profilo → Apple Salute: "Sincronizza adesso", "Importa tutto" e "Comandi rapidi" sono righe separate (prima un tocco poteva aprire la guida al posto della sincronizzazione) e quando Salute è collegata vedi i passi di oggi.
- "Cambia esercizio" ha il pulsante Chiudi.

## 4.12.1
- Serie e ripetizioni come le vuoi: i primi due esercizi di ogni seduta partono da 3 serie la prima settimana e salgono di una serie a settimana fino a 5, sempre tra 6 e 10 ripetizioni; poi aumenti i kg e si riparte da 3. Tutti gli altri esercizi stanno al massimo a 3 serie e 15 ripetizioni.

## 4.12
- Catalogo di oltre 870 esercizi (Free Exercise DB, pubblico dominio) con le illustrazioni animate di Fud AI (open source, MIT): in "Cambia esercizio" cerchi tra tutti, vedi l'animazione e le istruzioni e lo scegli per oggi. Le schede mostrano l'illustrazione animata quando l'esercizio è nel catalogo. Il catalogo si scarica la prima volta (circa 1 MB), poi funziona anche offline.
- Oggi ancora più semplice: restano anelli, "Cosa hai mangiato?", i pasti e il peso. Il tipo di giornata (allenamento/riposo) si imposta da solo quando segni una serie; i micronutrienti escono da Oggi.
- Test automatici su simulatore iPhone con iOS 27 che attraversano tutte le schermate e collegano Salute con tutti i permessi.

## 4.11
- Oggi più semplice: scrivi o tieni premuto e di' cosa hai mangiato ("a colazione caffè e 2 fette biscottate, a pranzo 80 g di pasta al pesto"). L'AI che hai scelto in Profilo (Claude, Gemini o quella dell'iPhone) riconosce alimenti e grammi e mette ogni cosa nel pasto giusto; se non dici il pasto, usa quello dell'ora. Un tocco annulla l'inserimento, toccando una voce correggi i grammi.
- Ultima seduta della scheda del Calendario (femorali e glutei) con 4 esercizi in più: hip thrust, calf in piedi, hyperextension per glutei e crunch al cavo.
- Molte più alternative in "Cambia esercizio" (oltre 130), anche per pullover, adductor e abductor machine.
- Apple Salute diretto: installando Nomorediet con Impactor dal PC (invece che con SideStore) il permesso di Salute resta, e puoi condividere solo passi e peso.

## 4.10.2
- Importazione da Salute più robusta: export.xml viene letto riga per riga, così l'intestazione del file che Salute scrive non blocca più la lettura. Se qualcosa va storto, il messaggio dice cosa e il pannello di debug (scuoti l'iPhone) mostra a che punto si è fermata.

## 4.10.1
- Da Salute a Nomorediet in un tocco: in Salute premi "Esporta tutti i dati sanitari" e nel foglio di condivisione scegli Nomorediet. L'app apre l'archivio da sola (non serve estrarlo) e importa tutto.

## 4.10
- Collegare l'AI senza copiare chiavi a mano: in Profilo → Analisi AI tocca "Accedi con Google e collega Gemini" (o "Accedi ad Anthropic" per Claude), entra con il tuo account, crea la chiave e premi Copia. Tornando in Nomorediet la chiave viene riconosciuta e collegata da sola.
- La chiave si salva nel Portachiavi iCloud quando è disponibile: dopo una reinstallazione o su un nuovo iPhone non va reinserita.
- Importa tutto da Salute: Profilo → Apple Salute → "Importa tutto da Salute". Esporti i dati dall'app Salute e Nomorediet legge tutto lo storico (passi, calorie, distanza, esercizio, piani, sonno, battito, HRV, VO₂ max, grasso corporeo) e tutte le pesate di sempre, da iPhone e Apple Watch. I passi contati sia dall'iPhone sia dal Watch non vengono sommati due volte.

## 4.9.9
- Allenamento saltato? Nessun problema: in Allenamento il riquadro "Oggi tocca" segue l'ultimo allenamento fatto, quindi quello saltato resta il prossimo. Con le frecce ‹ › torni indietro o vai avanti, "Inizia" lo apre.
- "Bravo, ce l'hai fatta! Hai finito l'allenamento": appena segni l'ultima serie della giornata (o premi Termina) compare il riepilogo, con le serie fatte e i kg sollevati, e il Coach te lo dice a voce.
- Serie a onde: una settimana 3 serie per esercizio, la successiva 4, poi 5. Dopo la settimana da 5 l'app ti propone più kg (+2,5 kg, +1 kg sui pesi sotto i 20) e si ricomincia da 3. Cambia da solo ogni lunedì; nel riquadro "Serie per esercizio questa settimana" puoi dire a che punto sei. Le settimane di scarico restano come sono.

## 4.9.8
- Segnare un pasto in un tocco: ogni pasto vuoto mostra "Come ieri" (ricopia quello che avevi mangiato ieri allo stesso pasto) e tre stime, Leggero, Normale e Abbondante, calcolate sul tuo obiettivo di calorie. Meglio una stima che un pasto mancante: il totale del giorno e l'andamento del peso restano affidabili. Puoi sempre aprire la voce e correggerla.
- Il promemoria serale ti ricorda di stimare i pasti che mancano.

## 4.9.7
- Leggi il nome dalla confezione: inquadra il prodotto, tocca la marca e il nome stampati sulla confezione e premi Cerca. Il testo viene letto sull'iPhone (senza internet), pulito da pesi e maiuscole, e cercato tra gli alimenti, nel database e su Open Food Facts, che danno il nome giusto del prodotto con i suoi valori. Lo trovi nella barra in basso della ricerca (icona testo) e nel menu + di ogni pasto.

## 4.9.6
- Comando rapido più semplice: nei campi di "Invia dati Salute a Nomorediet" puoi mettere direttamente il risultato di "Trova campioni di Salute", senza "Calcola statistiche". L'app somma passi, calorie, km e minuti, fa la media di battito e HRV e converte il sonno in ore.
- Se l'azione parte con i campi vuoti, ora te lo dice invece di rispondere "Ricevuto".
- "Sincronizza" avvia il comando sia se si chiama "Nomorediet Salute" sia se si chiama "Invia dati Salute a Nomorediet".

## 4.9.5
- "Sincronizza Salute" funziona anche con SideStore: avvia il comando rapido "Nomorediet Salute", che legge Salute e torna nell'app con i dati aggiornati. Lo trovi in Progressi (menu +), nel riquadro "Oggi da Apple Salute" (↻), in Profilo e trascinando verso il basso nel Coach.
- Tutti i dati sanitari: l'azione "Invia dati Salute a Nomorediet" riceve anche battito medio, HRV, VO₂ max, grasso corporeo e piani saliti, oltre a passi, calorie, km, minuti di esercizio, peso, sonno e battito a riposo. La guida in Profilo spiega come prendere ognuno da Salute.

## 4.9.4
- Progressi: nuovo grafico dei passi, accanto a quelli del peso e delle calorie. Mostra 7 o 30 giorni, con la linea a 8.000 passi, la media giornaliera e quanti giorni l'hai superata. I passi arrivano da Apple Salute tramite il comando rapido.

## 4.9.3
- Nuovo collegamento nomorediet://health: un comando rapido può passare i dati di Salute anche con "Apri URL", per esempio nomorediet://health?steps=8532&active=512&weight=84,6. I numeri vengono letti in qualunque formato (8.532, 84,6, 1,790.5).

## 4.9.2
- Apple Salute anche con SideStore: le app installate con un Apple ID gratuito non possono leggere Salute direttamente, quindi ora i dati arrivano da Comandi rapidi. La nuova azione "Invia dati Salute a Nomorediet" riceve passi, calorie attive e a riposo, peso, sonno, km e battito. Un'automazione serale li passa all'app anche quando è chiusa. La guida passo passo è in Profilo → Apple Salute.

## 4.9.1
- Palestra: la ricerca non resta più bloccata quando il GPS al chiuso è impreciso (al massimo 8 secondi, poi usa la posizione migliore trovata). Ogni risultato ha il pulsante "Scegli". Cerca anche tra gli indirizzi.
- Apple Salute: in Profilo, sotto l'interruttore, vedi se Salute è collegata davvero. Se non lo è, compare il motivo e il pulsante "Collega Apple Salute".

## 4.9
- Riconoscitore di piatti sul telefono: un modello di Google addestrato su 2.000 piatti (Apache-2.0) funziona anche offline. Dà un secondo parere all'AI, conferma che nella foto c'è cibo e, se non hai collegato nessuna AI, registra il piatto più probabile con la sua porzione standard. Anche su Android.
- Porzioni più precise: l'AI stima i grammi con la geometria. Prende come riferimento un oggetto di misura nota (piatto, forchetta, lattina, mano), ricava superficie e spessore di ogni alimento e poi volume × densità. Nella nota scrive quale riferimento ha usato.
- Per sviluppatori: con il kit iPhone (scripts/iphone) Claude Code può provare l'app su un iPhone collegato via cavo, toccando i pulsanti per nome e controllando ogni schermata con uno screenshot.

## 4.8
- Bilancia nella foto: se fotografi il cibo sulla bilancia da cucina, l'AI legge il peso sul display e lo usa come grammi (con più alimenti divide il totale in proporzione). Il peso netto stampato sulle confezioni non viene scambiato per la bilancia. Anche su Android.

## 4.7
- Primo avvio: la prima domanda è "Sei un uomo o una donna?". Calorie, proteine, scheda e animazioni si adattano: per le donne una scheda Nomorediet glutei e tonificazione e un personaggio atletico con la coda di cavallo; per gli uomini la scheda spalle e dorso e il personaggio muscoloso. Si cambia in Profilo.
- Nuova app per Android (cartella android/): stesse funzioni principali, installabile scaricando un file .apk.

## 4.6
- Accanto a Colazione, Pranzo, Spuntini e Cena ci sono due icone: 📷 foto e codice a barre, a un tocco.
- Ogni foto cerca anche il codice a barre: se c'è, il prodotto viene preso dal database (valori esatti dell'etichetta). Altrimenti l'app legge il nome e il tipo di prodotto scritti sulla confezione e li usa per riconoscerlo (anche senza AI, cercandolo nel database).
- Tolta la foto 3D (LiDAR).

## 4.5
- La scheda è quella del tuo Google Calendar (Ciclo 2): A1 Petto/Schiena lunedì, A2 Quadricipiti/Adduttori martedì, B1 Spalle/Braccia giovedì, B2 Femorali/Glutei venerdì, con jump set, recuperi, dropset 🔻 e alternative "se occupato". Il giorno di oggi è segnato "OGGI".
- Mesi del ciclo applicati da soli: mese 1 base, mese 2 tempo 3-1-1-0 e carichi −10%, scarico 12–18/10, mese 3 rest-pause e dropset doppi dal 19/10.
- "Aggiorna" legge di nuovo la scheda dal Calendario dell'iPhone (con l'account Google aggiunto): un nuovo ciclo scritto nel Calendar arriva nell'app senza aggiornamenti. Puoi tornare alla scheda Nomorediet dal selettore.
- Correggere gli errori: tocca una serie per cambiare peso, ripetizioni o RIR, oppure il cestino per eliminarla (con conferma). Nuovo "Storico serie" (icona orologio): modifica, scorri per eliminare o elimina un giorno intero.

## 4.4
- Scheda con priorità a spalle e dorso: Giorno 1 parte da lat machine presa neutra e rematore monolaterale al cavo; Giorno 3 diventa "spalle e dorso" con lat pulldown presa larga, rematore monolaterale al cavo basso, alzate laterali al cavo e face pull. Alzate laterali 4 volte a settimana, deltoide posteriore 2 volte (face pull, alzate posteriori al cavo al posto del crunch).
- Nuove animazioni: personaggio muscoloso in stile anime (fisico alla Baki) con muscoli disegnati, ombre a due toni, collo e trapezi possenti, vene sull'avambraccio; i muscoli che lavorano si "pompano" e si illuminano di rosso nel punto più duro della ripetizione.

## 4.3
- Tocca i secondi del recupero (es. "75 s") per far partire il timer; il timer resta visibile in alto mentre scorri la scheda.
- Apple Watch: timer in nero su sfondo bianco, leggibile al volo.

## 4.2
- Giorno 4: tolti crunch inverso/plank e affondi bulgari. Al loro posto alzate laterali al cavo (in coppia con l'hip thrust) e leg press piedi alti (glutei e femorali, in coppia con il calf).

## 4.1
- Coach: non inventa più serie. Un saluto non diventa mai un allenamento: le serie vengono proposte solo se le dici con i numeri e si salvano solo dopo "Salva".
- Voce del coach più realistica: voce neurale di Google se è collegata la chiave Gemini, altrimenti la migliore voce italiana dell'iPhone. Scelta uomo o donna e "Prova la voce".
- Apple Salute: passi, km, calorie attive e a riposo, minuti di esercizio, piani, battito medio, FC a riposo, HRV, sonno, VO₂ max, grasso corporeo e allenamenti, da iPhone e Apple Watch senza doppi conteggi. Nuova scheda "Oggi da Apple Salute" in Progressi; il coach conosce questi dati.
- Piano per dimagrire: scegli il peso da raggiungere (es. 80 kg) e la velocità; l'app calcola le calorie dal tuo mantenimento reale (Apple Salute o diario) meno il deficit, mostra la data del traguardo e il grafico. Dimagrire ora è sempre sotto il mantenimento (circa −550 kcal al giorno con il ritmo consigliato), mai sotto una soglia di sicurezza.
- Conta ripetizioni su tutti gli esercizi: con la fotocamera (ora anche croci, crunch e calf; posa 3D che funziona da qualsiasi angolazione, filtro anti-errori, si calibra sul tuo movimento) o con i sensori dell'iPhone (in tasca, al braccio o sul pacco pesi).

## 4.0
- Foto senza cibo: prima di qualsiasi AI, il classificatore di immagini dell'iPhone controlla che nella foto ci sia davvero cibo. Un computer o una scrivania non diventano più "una pagnotta": l'app lo dice e non aggiunge niente (con "È cibo, analizza comunque" se si sbaglia). Anche Apple, Gemini e Claude ora devono dire esplicitamente se c'è cibo.
- Tipo di dieta in Profilo: bilanciata, carb cycling, mediterranea, iperproteica, low carb, chetogenica. Con i giorni di allenamento della settimana.
- Scheda: progressione a blocchi di 4 settimane sui primi due esercizi (3 serie → 4 serie → 4 serie +2,5% → scarico), gli altri 3 × 10–15. "Cambia esercizio" se la macchina è occupata, con le alternative animate. Testi non più sovrapposti.
- Timer libero (preset o personalizzato) nella Dynamic Island, nella schermata di blocco e sull'Apple Watch.
- Chat con il coach, scritta o a voce: risponde a voce e salva le serie che gli racconti ("panca 60 kg 4x8").
- Promemoria integratori: multivitaminico ogni mattina; creatina 5 g dopo l'allenamento nei giorni di allenamento, al mattino nei giorni di riposo. "Presa ✓" dalla notifica o dalla schermata Oggi.
- Palestra: quando arrivi da Fit Active (o la palestra che scegli) ti apre l'allenamento di oggi; quando esci dopo esserti allenato ti ricorda la creatina.
- Il "+" sceglie il pasto dall'orario (colazione, spuntino, pranzo, cena); tocca il titolo per cambiarlo.
- Nuove animazioni degli esercizi in stile anime: personaggio con contorni e ombre, scie di movimento, linee di velocità, muscolo che si illumina sotto sforzo.
- Richiede iOS 18 o successivo.

## 3.9
- Aggiornamenti anche con Sideloadly: se SideStore non è installato, "Aggiorna" apre la pagina per scaricare la nuova versione.

## 3.8
- Aggiornamenti dell'app via internet (OTA): ogni nuova versione viene pubblicata automaticamente come fonte SideStore. L'app controlla da sola, mostra un avviso "Nuova versione disponibile" e SideStore la installa con un tocco, senza perdere i dati. Sezione "Aggiornamenti app" in Profilo.

## 3.7
- Aggiornamenti del database via internet (OTA): ogni 7 giorni l'app scarica da sola, in background, i prodotti italiani nuovi o modificati su Open Food Facts; "Aggiorna ora" in Profilo. I prodotti trovati con il codice a barre online restano salvati sul telefono.

## 3.6
- Database grande sul telefono: tutti i prodotti venduti in Italia su Open Food Facts + alimenti e piatti generici USDA, ricostruito ogni settimana da GitHub Actions. Ricerca e codici a barre funzionano anche senza internet; il riconoscimento AI cerca qui gli alimenti che non sono nella tabella di base.

## 3.5
- Nuovo algoritmo di riconoscimento (ispirato a DietAI24): l'AI riconosce alimenti e porzioni, calorie e nutrienti vengono dalla tabella; valori del modello solo per alimenti assenti, segnati "stima AI".
- Descrivi il pasto a voce o per iscritto ("Dillo"), con lo stesso algoritmo; funziona anche senza AI per frasi come "200 g di riso, 2 uova".

## 3.4
- Gemini come terzo motore di analisi: gratuito entro i limiti di Google, con chiave personale creata su AI Studio (pulsante diretto, incolla, collega). L'app sceglie da sola il modello Flash più recente.

## 3.3
- Analisi delle foto gratuita con il modello di Apple sull'iPhone (iOS 27, Apple Intelligence): la foto non esce dal telefono. È il motore predefinito; Claude resta disponibile con la chiave API.
- Compilazione con Xcode 27.

## 3.2
- Limiti e costi AI: interruttore, budget mensile, analisi al giorno, una richiesta alla volta, 3 tentativi con attesa crescente, avviso all'80%, registro dei costi.
- Test automatici in GitHub Actions; manifest della privacy; documentazione di progetto.

## 3.1
- Analisi AI facoltativa della foto del piatto (anche con il volume del LiDAR), con revisione dei grammi e memoria delle correzioni.

## 3.0
- Riscrittura nativa in SwiftUI: diario, ricerca alimenti e Open Food Facts, codice a barre, etichette, peso a voce e da foto, grafici e previsione, calorie adattive, scheda in jump set con registro, coach, livelli, profilo. Funziona senza account.

## 2.x
- Versione web dentro un guscio Swift (sostituita).
