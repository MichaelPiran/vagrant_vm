# Gestione VM Hyper-V

Il repository contiene tre strumenti indipendenti. Eseguire i comandi da
PowerShell su Windows con i permessi Hyper-V richiesti.

| Strumento | Quando usarlo | Dati |
| --- | --- | --- |
| [vmctl-hv](vmctl-hv/README.md) | Nuove VM Hyper-V senza Vagrant, con immagini cloud e cloud-init. Prototipo: consultare i limiti nel README. | `%USERPROFILE%\.hvctl` |
| [vmctl-go](vmctl-go/README.md) | Client Go interattivo per VM Vagrant: Ubuntu 22, Debian 9 e 12, Arch e Alpine 3.18. | `%USERPROFILE%\.vagrant-vm` |
| [vagrant](vagrant/README.md) | Flusso Vagrant originale con Makefile e file `.env`; utile per le VM esistenti. | `configs/` e cartelle VM nella root del repository |

Ogni directory ha il proprio Makefile; non esiste un Makefile globale. I due
client hanno configurazioni e dati separati e non gestiscono automaticamente le
VM create dall'altro. `hvctl` può importare alcuni `.env` Vagrant con
`-FromEnv`, creando una nuova VM; non trasferisce una VM esistente.

Le configurazioni personali, `local.mk`, le cartelle delle VM e gli eseguibili
compilati sono ignorati da Git. I sorgenti dei tre strumenti sono condivisibili.
Per preservare le installazioni esistenti, il flusso originale continua a usare
le cartelle locali `configs/` e `<nome-vm>/` nella root: non spostarle senza
verificare prima lo stato Vagrant. Consultare il [README legacy](vagrant/README.md)
per i comandi aggiornati e la configurazione.