# Flusso Vagrant originale

Questi comandi usano Windows, Hyper-V, Vagrant, OpenSSH e `make`. Aprire
PowerShell come amministratore e lavorare da questa directory:

```powershell
cd vagrant
make list
make new VM=debian12-vm
make up VM=debian12-vm
make connect VM=debian12-vm
make start VM=debian12-vm
make destroy VM=debian12-vm
```

Il Makefile invoca [manage.ps1](manage.ps1); `list` elenca tutte le VM Hyper-V,
anche quelle non create con questo strumento, e non richiede una configurazione.
`destroy` distrugge la VM Vagrant e rimuove i relativi dati locali e la chiave SSH.
`make test` verifica il flusso locale senza creare o avviare VM Hyper-V.

## Configurazione e compatibilità

Per conservare le VM esistenti, i file personali restano nella root del
repository: `configs/<nome>.env`, `local.mk` e `<VM_NAME>/` con i dati
`.vagrant`. Non sono tracciati da Git. Il default è `VM=debian12-vm`; un
`local.mk` nella root può sovrascriverlo, come in precedenza. È possibile
usare anche `vagrant/local.mk`, che ha precedenza su quello nella root. Il
parametro `VM=...` sulla riga di comando ha precedenza su entrambi.

Per una nuova configurazione, copiare [configs/example.env](configs/example.env)
in `../configs/<nome>.env` e adattare nome, IP, gateway, switch e box alla
propria rete. I percorsi possono essere cambiati con `CONFIG_DIR` e `VM_ROOT`
nel `local.mk` o sulla riga di comando, relativi alla directory `vagrant`.
Non cambiare `VM_ROOT` per una VM esistente senza prima verificare come
Vagrant ne conserva lo stato.

## Provisioning

`make up` copia sempre il Vagrantfile e i provisioner aggiornati nella cartella
della VM. `VM_PROVISIONER` seleziona `ubuntu` (Netplan), `debian` (cloud-init
e ifupdown o systemd-networkd), `arch` (systemd-networkd) o `alpine` (OpenRC).
Gli script configurano rete e SSH; la box deve prima ottenere un indirizzo per
consentire a Vagrant di collegarsi e avviare il provisioning.

`VM_BOX_VERSION` e `VM_BOX_ARCHITECTURE` fissano versione e architettura
della box; per Debian 12 usare `4.3.12` e `amd64`.
