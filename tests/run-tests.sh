#!/bin/bash
# Tests de clone-vm.sh avec des faux virsh / virt-clone / virt-sysprep.
# Usage : run-tests.sh /chemin/vers/clone-vm.sh

SCRIPT="$1"
T="$(cd "$(dirname "$0")" && pwd)"
export PATH="$T/bin:$PATH"
export FAKE_STATE="$T/state" FAKE_LOG="$T/log" FAKE_FB="$T/firstboot"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  OK    %s\n' "$1"; }
ko()  { fail=$((fail+1)); printf '  ECHEC %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

# remet a zero l'hote simule : chaque argument = "nom etat"
reset() { : > "$FAKE_STATE"; : > "$FAKE_LOG"; rm -f "$FAKE_FB"; for vm in "$@"; do echo "$vm" >> "$FAKE_STATE"; done; }

# lance le script ; sortie dans $OUT, code de retour dans $RC
run() { OUT=$(CLONE_VM_CONFIG="${CFG:-/nonexistent}" "$SCRIPT" "$@" 2>&1 </dev/null); RC=$?; }
has() { grep -qF -- "$1" <<<"$OUT"; }
logged() { grep -qF -- "$1" "$FAKE_LOG"; }

echo "== Aide et validation des arguments =="
reset; run --version
[ $RC -eq 0 ] && has "clone-vm.sh 1." && ok "--version" || ko "--version" "$OUT"

reset; run
[ $RC -ne 0 ] && has "no template VM given" && ok "refuse sans -t" || ko "refuse sans -t" "$OUT"

reset "base shut off"; run -t absente -y
[ $RC -ne 0 ] && has "not found" && ok "modele inexistant" || ko "modele inexistant" "$OUT"

reset "base running"; run -t base -y
[ $RC -ne 0 ] && has "Shut it down first" && ok "refuse un modele allume" || ko "refuse un modele allume" "$OUT"

reset "base shut off" "web shut off"; run -t base -n web -y
[ $RC -ne 0 ] && has "already exists" && ok "refuse un nom deja pris" || ko "refuse un nom deja pris" "$OUT"

reset "base shut off"; run -t base -n web -p client -y
[ $RC -ne 0 ] && has "not both" && ok "refuse -n et -p ensemble" || ko "refuse -n et -p ensemble" "$OUT"

reset "base shut off"; run -t base -n bad_name -y
[ $RC -ne 0 ] && has "not a valid hostname" && ok "refuse un nom d'hote invalide (_)" || ko "nom invalide (_)" "$OUT"

reset "base shut off"; run -t base -n web- -y
[ $RC -ne 0 ] && has "not a valid hostname" && ok "refuse un tiret final" || ko "tiret final" "$OUT"

reset "base shut off"; run -t base -m abc -y
[ $RC -ne 0 ] && has "must be a number" && ok "refuse --max non numerique" || ko "--max" "$OUT"

echo "== Systeme en francais (virsh traduit ses etats) =="
# Les tests tournent sinon en anglais : on force le francais ici.
run_fr() { OUT=$(env -u LC_ALL -u LC_MESSAGES LANG=fr_FR.UTF-8 CLONE_VM_CONFIG=/nonexistent "$SCRIPT" "$@" 2>&1 </dev/null); RC=$?; }

reset "base shut off"; run_fr -t base -n web-02 -y
[ $RC -eq 0 ] && logged "--name web-02" && ok "modele eteint ('ferme') accepte" || ko "modele eteint en francais" "rc=$RC $OUT"

reset "base running"; run_fr -t base -n web-02 -y
[ $RC -ne 0 ] && has "Shut it down first" && ! logged "CLONE" && ok "modele allume refuse" || ko "modele allume en francais" "rc=$RC $OUT"
has "sudo virsh shutdown" && ok "le conseil d'arret contient sudo" || ko "conseil d'arret sans sudo" "$OUT"

echo "== Suite de la validation =="
reset "base shut off"; run -t base --nimporte -y
[ $RC -ne 0 ] && has "unknown option" && ok "refuse une option inconnue" || ko "option inconnue" "$OUT"

echo "== Choix du nom =="
reset "base shut off" "client1 shut off" "client2 running"; run -t base -p client -y
[ $RC -eq 0 ] && logged "--name client3" && ok "-p prend le premier libre (client3)" || ko "premier libre" "$OUT"

reset "base shut off" "client1 shut off" "client3 shut off"; run -t base -p client -y
[ $RC -eq 0 ] && logged "--name client2" && ok "-p comble un trou (client2)" || ko "combler un trou" "$OUT"

reset "base shut off"; run -t base -y
[ $RC -eq 0 ] && logged "--name base1" && ok "sans -n/-p : modele + numero (base1)" || ko "nom par defaut" "$OUT"

reset "base shut off"; run -t base -n web-02 -y
[ $RC -eq 0 ] && logged "--name web-02" && ok "-n nom exact" || ko "-n nom exact" "$OUT"

reset "base shut off" "c1 shut off" "c2 shut off"; run -t base -p c -m 2 -y
[ $RC -ne 0 ] && has "no free name" && ok "--max atteint : erreur claire" || ko "--max atteint" "$OUT"

echo "== Ce qui est transmis a virt-sysprep =="
reset "base shut off"; run -t base -n web-02 -y
logged "[--hostname] [web-02]" && ok "nom d'hote transmis" || ko "nom d'hote" "$(cat "$FAKE_LOG")"
logged "[--firstboot]" && ok "script de 1er demarrage transmis" || ko "firstboot"
! logged "ssh-userdir" && ok "sans -k : ~/.ssh n'est pas protege" || ko "sans -k"
logged "START web-02" && ok "le clone est demarre" || ko "demarrage"

reset "base shut off"; run -t base -n web-02 -k -d '/var/lib/glpi-agent/*' -d '/var/lib/zabbix/*' -y
logged "[--operations] [defaults,-ssh-userdir]" && ok "-k garde ~/.ssh" || ko "-k" "$(cat "$FAKE_LOG")"
logged "[--delete] [/var/lib/glpi-agent/*]" && logged "[--delete] [/var/lib/zabbix/*]" \
  && ok "-d repetable, chemins non developpes par le shell" || ko "-d" "$(cat "$FAKE_LOG")"

reset "base shut off"; run -t base -n web-02 --no-sysprep -y
[ $RC -eq 0 ] && ! logged "SYSPREP" && ok "--no-sysprep : pas de virt-sysprep" || ko "--no-sysprep"

reset "base shut off"; run -t base -n web-02 --no-start -y
[ $RC -eq 0 ] && ! logged "START" && ok "--no-start : clone laisse eteint" || ko "--no-start"

echo "== Modes sans risque =="
reset "base shut off"; run -t base -n web-02 --dry-run
[ $RC -eq 0 ] && has "[dry-run]" && ! logged "CLONE" && ! grep -q "^web-02 " "$FAKE_STATE" \
  && ok "--dry-run : affiche, ne cree rien" || ko "--dry-run" "$OUT"
has "nothing was changed" && ! has "is ready" \
  && ok "--dry-run : ne pretend pas que le clone est pret" || ko "message de fin du dry-run" "$OUT"

reset "base shut off"; OUT=$(CLONE_VM_CONFIG=/nonexistent "$SCRIPT" -t base -n web-02 2>&1 <<<"n"); RC=$?
[ $RC -eq 0 ] && grep -q "Cancelled" <<<"$OUT" && ! logged "CLONE" && ok "reponse n : annule, rien cree" || ko "reponse n" "$OUT"

reset "base shut off"; run -t base -n web-02
[ $RC -eq 0 ] && has "Cancelled" && ! logged "CLONE" && ok "sans terminal ni -y : annule proprement" || ko "sans terminal ni -y" "rc=$RC sortie: $OUT"

echo "== Script de 1er demarrage =="
reset "base shut off"; run -t base -n web-02 -c 'glpi-agent --force' -c 'sed -i "s/^Hostname=.*/Hostname=$(hostname)/" /etc/z.conf' -y
if [ -f "$FAKE_FB" ]; then
  sh -n "$FAKE_FB" && ok "syntaxe sh valide" || ko "syntaxe sh"
  grep -q "127.0.1.1 web-02" "$FAKE_FB" && ok "nom injecte dans /etc/hosts" || ko "/etc/hosts"
  grep -q "ssh-keygen -A" "$FAKE_FB" && ok "regeneration des cles SSH" || ko "ssh-keygen"
  a=$(grep -n "glpi-agent --force" "$FAKE_FB" | cut -d: -f1); b=$(grep -n "Hostname=" "$FAKE_FB" | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && ok "commandes -c presentes, dans l'ordre" || ko "ordre -c"
  grep -qF '$(hostname)' "$FAKE_FB" && ok '$(hostname) garde tel quel (evalue dans le clone)' || ko '$(hostname)'
  w=$(grep -n "_wait=0" "$FAKE_FB" | cut -d: -f1)
  [ -n "$w" ] && [ "$w" -lt "$a" ] && ok "attente du reseau avant les commandes" || ko "attente reseau"
else ko "firstboot non genere" "$OUT"; fi

reset "base shut off"; run -t base -n web-02 --no-ssh-keys -y
! grep -q "ssh-keygen" "$FAKE_FB" && ok "--no-ssh-keys : pas de ssh-keygen" || ko "--no-ssh-keys"

echo "== Fichier de config =="
CFG="$T/test.conf"
cat > "$CFG" <<'EOC'
TEMPLATE="base"
PREFIX="client"
EXTRA_DELETE=('/var/lib/glpi-agent/*')
FIRSTBOOT_COMMANDS=('glpi-agent --force')
EOC
reset "base shut off" "client1 shut off"; run -y
[ $RC -eq 0 ] && logged "--name client2" && logged "[--delete] [/var/lib/glpi-agent/*]" && grep -q "glpi-agent --force" "$FAKE_FB" \
  && ok "profil complet depuis le fichier, sans argument" || ko "fichier de config" "$OUT"

reset "base shut off"; run -t base -n special -y
[ $RC -eq 0 ] && logged "--name special" && ok "-n en ligne de commande l'emporte sur PREFIX du fichier" || ko "-n contre PREFIX du fichier" "rc=$RC sortie: $(tail -2 <<<"$OUT")"

reset "base shut off" "autre shut off"; run -t autre -y
[ $RC -eq 0 ] && logged "--original autre" && ok "-t en ligne de commande l'emporte sur TEMPLATE du fichier" || ko "-t contre fichier" "$OUT"
unset CFG

echo "== Execution reelle du 1er demarrage (bac a sable) =="
# On genere le script, on remplace /etc/hosts, /etc/ssh, etc. par des
# fichiers du bac a sable, et on l'execute avec des faux ssh-keygen,
# systemctl, ip et sleep.
SB="$T/sandbox"; export SB
fb_run() {  # $1 = contenu initial de hosts, $2 = 1 si des cles SSH existent deja
  rm -rf "$SB"; mkdir -p "$SB/ssh" "$SB/stubs"
  printf '%b' "$1" > "$SB/hosts"
  [ "$2" = 1 ] && touch "$SB/ssh/ssh_host_ed25519_key"
  cat > "$SB/stubs/ssh-keygen" <<'S'
#!/bin/sh
echo "ssh-keygen $*" >> "$SB/calls"; touch "$SB/ssh/ssh_host_ed25519_key"
S
  printf '#!/bin/sh\necho "systemctl $*" >> "$SB/calls"\n' > "$SB/stubs/systemctl"
  printf '#!/bin/sh\necho "default via 192.168.122.1 dev enp1s0"\n' > "$SB/stubs/ip"
  printf '#!/bin/sh\n:\n' > "$SB/stubs/sleep"
  chmod +x "$SB/stubs/"*
  sed -e "s|/etc/hosts|$SB/hosts|g" -e "s|/etc/ssh|$SB/ssh|g" -e "s|/tmp/FBOUT|$SB/out|g" "$FAKE_FB" > "$SB/fb.sh"
  PATH="$SB/stubs:$PATH" sh "$SB/fb.sh"
}

reset "base shut off"
run -t base -n web-02 -c 'echo premier >> /tmp/FBOUT' -c 'echo second >> /tmp/FBOUT' -y

fb_run '127.0.0.1 localhost\n127.0.1.1 vieux-nom\n::1 ip6-localhost\n' 0
grep -qx "127.0.1.1 web-02" "$SB/hosts" && ! grep -q "vieux-nom" "$SB/hosts" \
  && ok "ancienne ligne 127.0.1.1 remplacee par le nouveau nom" || ko "remplacement hosts" "$(cat "$SB/hosts")"
grep -qx "127.0.0.1 localhost" "$SB/hosts" && grep -qx "::1 ip6-localhost" "$SB/hosts" \
  && ok "les autres lignes de /etc/hosts sont intactes" || ko "autres lignes hosts" "$(cat "$SB/hosts")"
grep -q "ssh-keygen -A" "$SB/calls" && grep -q "systemctl restart ssh" "$SB/calls" \
  && ok "sans cles : ssh-keygen -A puis redemarrage de ssh" || ko "regeneration ssh" "$(cat "$SB/calls" 2>/dev/null)"
[ "$(cat "$SB/out" 2>/dev/null)" = "$(printf 'premier\nsecond')" ] \
  && ok "commandes -c executees, dans l'ordre" || ko "execution -c" "$(cat "$SB/out" 2>/dev/null)"

fb_run '127.0.0.1 localhost\n' 0
grep -qx "127.0.1.1 web-02" "$SB/hosts" && [ "$(grep -c '^127.0.1.1' "$SB/hosts")" -eq 1 ] \
  && ok "sans ligne 127.0.1.1 : elle est ajoutee, une seule fois" || ko "ajout hosts" "$(cat "$SB/hosts")"

fb_run '127.0.1.1 vieux-nom\n' 1
! grep -q "ssh-keygen" "$SB/calls" 2>/dev/null \
  && ok "cles deja presentes : ssh-keygen n'est pas relance" || ko "cles existantes" "$(cat "$SB/calls")"

echo
echo "Resultat : $pass reussis, $fail echoues"
[ $fail -eq 0 ]
