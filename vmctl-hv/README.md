# vmctl-hv (prototipo)

Crea e gestisce VM Hyper-V **senza Vagrant**: immagini cloud ufficiali + cloud-init + cmdlet `Hyper-V` nativi.
Cartella indipendente da `vmctl-go` e dal `Makefile` principale.

## Come funziona

1. `pull` scarica l'immagine cloud una sola volta e la converte in `.vhdx` (`qemu-img`).
2. `new` copia il `.vhdx` base, lo espande, genera una chiave SSH ed25519 e un ISO `cidata`
   (IP statico, hostname, utente, chiave) con IMAPI2 (integrato in Windows), poi crea la VM Gen2.
3. L'avvio avviene con cloud-init: niente provisioner, niente Ruby, niente SMB.
   La NIC e' riconosciuta tramite MAC statico deterministico.

## Requisiti

- Hyper-V abilitato e utente in "Hyper-V Administrators" (o PowerShell admin);
- `qemu-img` (solo per `pull`): `winget install SoftwareFreedomConservancy.QEMU`;
- OpenSSH Client e `curl.exe` (inclusi in Windows 10/11).

## Build

```powershell
make build        # genera hvctl.exe
make test         # smoke test degli script + test Go
```

`hvctl.exe` contiene gli script PowerShell (`go:embed`): si puo' copiare in qualsiasi cartella (o aggiungerla al
`PATH`) senza portarsi dietro `lib\`. Al primo avvio estrae gli script in `%LOCALAPPDATA%\hvctl\scripts\<hash>` e li
esegue con Windows PowerShell; una nuova versione dell'eseguibile usa una nuova cartella. Servono Go 1.22+ e `make`
solo per compilare. In sviluppo si puo' usare direttamente `.\hvctl.ps1` al posto di `hvctl`.

## Uso

Senza argomenti (`hvctl`) si apre il **menu interattivo**: frecce su/giu, `Invio` per selezionare,
`Esc` per tornare indietro, `Ctrl+C` per uscire. Elenca le VM create (stato, IP, immagine) e permette di
crearne una nuova con procedura guidata (scarica l'immagine se manca) e, per ogni VM, di avviarla,
connettersi via SSH, fermarla o fare destroy.

Gli stessi comandi sono disponibili da riga di comando:

```powershell
hvctl images                  # elenco immagini disponibili e stato (anche: pull senza argomenti)
hvctl pull ubuntu26
hvctl new web1 -User mario -Image ubuntu26                      # gateway e IP automatici
hvctl new web1 -User mario -Image ubuntu26 -Ip 192.168.0.20 -Gateway 192.168.0.1
hvctl new debian12-vm -User mario -FromEnv ..\configs\debian12-vm.env   # riusa i vecchi .env
hvctl list
hvctl connect web1
hvctl console web1 -Start             # avvia la VM e mostra/salva il log di boot (porta seriale)
hvctl console web1 [-Seconds 60]      # collega la console di una VM gia' accesa
hvctl stop web1 [-Force]
hvctl up web1
hvctl destroy web1 [-Force]
```

Opzioni di `new`: `-Image`, `-Ip`, `-Gateway`, `-PrefixLength` (24), `-Dns`, `-VmSwitch` (VMSwitchNat),
`-MemoryMB` (1024), `-MaxMemoryMB` (4096), `-Cpus` (2), `-DiskGB` (20), `-User` (obbligatorio), `-NoStart`.

**Accesso alla VM.** Il menu chiede il nome utente Linux; da riga di comando lo si indica con `-User`.
Non viene impostata alcuna password: la password dell'account e' bloccata e l'accesso SSH con password e' disabilitato.
`hvctl connect` usa il nome scelto e la chiave SSH generata per la VM. L'utente puo' usare `sudo` senza password.

**IP automatico.** Se `-Gateway` manca viene letto dall'adattatore `vEthernet (<switch>)` dell'host; se manca `-Ip`
(e nel menu come valore suggerito) si sceglie il primo IP libero della subnet a partire da `.10`, escludendo:
VM hvctl, VM Hyper-V con IP noto, voci ARP dell'host, IP dei vecchi `configs\*.env` / `~\.vagrant-vm\configs`
e gli indirizzi che rispondono al ping.

**Console / log di boot.** Ogni VM ha la COM1 collegata alla named pipe `\\.\pipe\hvctl-<nome>`; il kernel Linux e
cloud-init scrivono li' il log di avvio. `console` lo mostra a schermo (`q` o `Esc` per terminare) e lo accoda in
`vms\<nome>\console.log`, utile quando la console grafica di Hyper-V fa scorrere via il messaggio di errore.
Usare `-Start` per catturare il boot dall'inizio: collegandosi a una VM gia' avviata si vede solo l'output successivo.
Le VM create prima di questa funzione vengono configurate al primo `console` (devono essere spente).
Nel menu e' la voce "Console (log di avvio)". La pipe accetta un solo client alla volta.

Dati in `%USERPROFILE%\.hvctl` (override: `HVCTL_HOME`): `images\` (base VHDX) e `vms\<nome>\`
(disco, `seed.iso`, `vm.json`).

Come `vmctl-go`, la chiave SSH di ogni VM e' copiata in `~\.ssh\hvctl\<nome>` (creata da `new`, usata da `connect`).
`new` e `destroy` rimuovono da `~\.ssh\known_hosts` la voce dell'IP della VM; `destroy` elimina anche la cartella della chiave.

## Limiti del prototipo

- Immagini: Ubuntu 26.04, Debian 12 (variante `generic`: `genericcloud` ha un kernel senza driver Hyper-V), Arch Linux.
  Ubuntu 22/24, Debian 9 e Alpine 3.18 non sono nel catalogo; `-FromEnv` rifiuta i box senza immagine equivalente.
- Solo IP statico IPv4; Secure Boot disattivato; nessuna verifica di checksum delle immagini.
- Il boot reale delle immagini su Hyper-V non e' stato provato qui: verificare con `new` + `connect`.
  Il test end-to-end senza avvio (creazione VM, firmware, DVD, destroy) e' stato eseguito con un VHDX fittizio.

## Test

```powershell
powershell -File tests\smoke.ps1   # MAC, network-config, parsing .env, ISO cidata, navigazione del menu (non richiede Hyper-V)
```
