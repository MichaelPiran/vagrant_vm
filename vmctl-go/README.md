# vmctl

Utility interattiva in Go per creare e gestire VM Vagrant con Hyper-V.

## Requisiti

- Windows con Hyper-V abilitato;
- Vagrant disponibile nel `PATH`;
- OpenSSH Client di Windows;
- PowerShell o Windows Terminal avviato come amministratore;
- Go 1.22 o successivo, necessario solo per compilare.

## Compilazione

```powershell
make build
```

Per vedere tutti i comandi disponibili usare `make help`. Ad esempio:

```powershell
make run
make list
make new
make up VM=ubuntu22-vm
make connect VM=ubuntu22-vm
make destroy VM=ubuntu22-vm
```

Avviare `vmctl.exe` senza argomenti per il menu, oppure usare direttamente:

```powershell
vmctl list
vmctl new
vmctl up <nome>
vmctl connect <nome>
vmctl destroy <nome>
```

Nel menu interattivo usare le frecce su/giu per spostarsi, `Invio` per
selezionare e `Ctrl+C` per uscire.

I dati sono conservati in `%USERPROFILE%\.vagrant-vm`:

- `images`: catalogo delle immagini ammesse (Ubuntu 22, Debian 9 e Arch Linux);
- `configs`: configurazioni `.env` delle VM create;
- `vms`: `Vagrantfile`, provisioner e dati `.vagrant` di ogni VM.

Per usare una directory diversa impostare `VMCTL_HOME`.

La connessione usa direttamente `ssh.exe` con la chiave Vagrant copiata in
`%USERPROFILE%\.ssh\vagrant\<nome-vm>`, evitando l'avvio di Ruby/Vagrant a ogni
accesso. `destroy` rimuove la copia della chiave e la voce IP da `known_hosts`.