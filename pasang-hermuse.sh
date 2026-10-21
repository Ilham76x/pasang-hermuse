#!/usr/bin/env bash
# =====================================================================
# pasang-hermuse.sh — instal OTOMATIS Hermuse (Hermes Agent + 9Router)
# untuk VPS / workspace BARU (Ubuntu/Debian), sekali jalan dari root.
#
# Yang dikerjakan skrip ini:
#   1. Membuka login SSH root (drop-in 00, nilai pertama menang di sshd)
#   2. Mengunduh repo Hermuse dari GitHub (atau memperbarui bila ada)
#   3. Memasang Hermes dari GitHub+PyPI via uv (Python 3.14), lalu
#      menjalankan installer repo untuk 9Router
#   4. Membuat password dashboard 9Router (diprint SEKALI di akhir)
#   5. Menyetel Hermes memakai 9Router lokal (127.0.0.1:20128),
#      model default gemini/gemini-3.8-flash — sama seperti produksi
#   6. Meminta TOKEN BOT UJI + ID Telegram (ditik di VPS, TIDAK pernah
#      disimpan di dalam skrip ini), menulis ~/.hermes/.env (chmod 600)
#   7. Menyalakan 9Router + gateway Telegram, memasang watchdog cron
#   8. Menjalankan doctor.sh sebagai pemeriksaan akhir
#
# Sisa langkah manual (memang hanya bisa oleh pemilik akun):
#   - Menambah koneksi API key Gemini di dashboard 9Router, ATAU
#     menjalankan: hermes setup --portal  (login Nous, otak instan)
#
# Cara pakai (sebagai root):
#   bash pasang-hermuse.sh
# =====================================================================
set -uo pipefail

log()  { printf '\n[paham] %s\n' "$*"; }
warn() { printf '\n[paham] PERINGATAN: %s\n' "$*" >&2; }
die()  { printf '\n[paham] BERHENTI: %s\n' "$*" >&2; exit 1; }

# Input selalu dari terminal asli, supaya aman dijalankan lewat
# bash <(curl ...) — read tidak memakan aliran skrip.
IN=/dev/stdin
[ -r /dev/tty ] && IN=/dev/tty

# --- 0. Harus root ---------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Jalankan sebagai root. Masuk dulu: sudo -i (atau ssh root@localhost dari user biasa), lalu ulangi."

REPO_DIR="$HOME/Hermuse"
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
export DEBIAN_FRONTEND=noninteractive

# --- 1. Login SSH root ----------------------------------------------
log "Langkah 1/8: membuka login SSH root..."
printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/00-rootlogin.conf
systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null || warn "restart ssh gagal — login root berlaku setelah restart berikutnya."

# --- 2. Alat dasar ----------------------------------------------------
log "Langkah 2/8: memastikan git, curl, sudo tersedia..."
command -v git  >/dev/null 2>&1 || { apt-get update -y && apt-get install -y git; }
command -v curl >/dev/null 2>&1 || apt-get install -y curl
command -v sudo >/dev/null 2>&1 || apt-get install -y sudo

# --- 3. Repo Hermuse ---------------------------------------------------
log "Langkah 3/8: mengambil repo Hermuse..."
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" pull --ff-only || warn "git pull gagal — lanjut dengan repo yang ada."
else
  git clone https://github.com/imkofty/Hermuse.git "$REPO_DIR" || die "git clone gagal — cek koneksi internet VPS."
fi

# --- 4. Hermes Agent lewat GitHub + PyPI (uv) ------------------------------
# Installer resmi Hermes mengunduh dari hermes-agent.nousresearch.com —
# di sebagian jaringan (mis. prepare.sh) alamat itu timeout. Jalur ini
# memakai HANYA github.com + pypi.org: uv mengunduh Python 3.14 mandiri
# (Hermes versi sekarang wajib >= 3.14), lalu memasang hermes-agent
# dari checkout GitHub-nya.
log "Langkah 4/8: memasang Hermes Agent lewat GitHub + uv (Python 3.14)..."
if ! command -v hermes >/dev/null 2>&1; then
  apt-get install -y python3-venv || warn "python3-venv gagal dipasang."
  if ! command -v uv >/dev/null 2>&1; then
    python3 -m venv "$HOME/.uvboot" || die "gagal membuat venv untuk uv."
    "$HOME/.uvboot/bin/pip" install -q uv || die "gagal memasang uv dari PyPI."
    export PATH="$HOME/.uvboot/bin:$PATH"
  fi
  [ -d "$HOME/.hermes/hermes-agent/.git" ] || \
    git clone https://github.com/NousResearch/hermes-agent.git "$HOME/.hermes/hermes-agent" || die "clone hermes-agent gagal."
  uv venv --python 3.14 "$HOME/.hermes-venv" || die "uv gagal menyiapkan Python 3.14."
  uv pip install --python "$HOME/.hermes-venv/bin/python" -e "$HOME/.hermes/hermes-agent" || die "instal hermes-agent dari sumber gagal."
  mkdir -p "$HOME/.local/bin"
  ln -sf "$HOME/.hermes-venv/bin/hermes" "$HOME/.local/bin/hermes"
fi
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
command -v hermes >/dev/null 2>&1 || die "perintah hermes tetap tidak ditemukan — kirim log-nya ke Zero."

# --- 4b. Installer repo (9Router; Hermes terdeteksi sudah ada) ---------------
log "Langkah 4b/8: menjalankan installer repo Hermuse (9Router)..."
bash "$REPO_DIR/scripts/install.sh" || die "installer repo berhenti dengan error — kirim potongan log terakhirnya ke Zero."
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

# --- 5. Password dashboard 9Router --------------------------------------
DASH_PW=""
if [ ! -f "$REPO_DIR/.dashboard-pw" ]; then
  DASH_PW="$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)"
  printf '%s' "$DASH_PW" > "$REPO_DIR/.dashboard-pw"
  chmod 600 "$REPO_DIR/.dashboard-pw"
  log "Password dashboard 9Router dibuat (tersimpan di .dashboard-pw, chmod 600)."
else
  log "Password dashboard 9Router sudah ada — tidak diubah."
fi

# --- 6. Hermes -> 9Router lokal ------------------------------------------
log "Langkah 6/8: menyetel model Hermes ke 9Router lokal..."
hermes config set model.provider custom            || warn "config model.provider gagal."
hermes config set model.base_url http://127.0.0.1:20128/v1 || warn "config model.base_url gagal."
hermes config set model.default gemini/gemini-3.8-flash    || warn "config model.default gagal."

# --- 7. Token bot uji + ID Telegram ---------------------------------------
log "Langkah 7/8: data bot Telegram (ketik di sini, tidak lewat chat)."
TGID_DEFAULT=6085361150
printf 'ID Telegram kamu [%s]: ' "$TGID_DEFAULT" >&2
read -r TGID < "$IN" || TGID=""
[ -z "${TGID:-}" ] && TGID="$TGID_DEFAULT"

TOKEN=""
try=0
while [ -z "$TOKEN" ] && [ $try -lt 3 ]; do
  try=$((try+1))
  printf 'Tempel TOKEN BOT UJI dari BotFather (ketikan disembunyikan): ' >&2
  read -rs TOKEN < "$IN" || TOKEN=""
  printf '\n' >&2
  case "$TOKEN" in
    *:*) : ;;
    *) warn "Format token sepertinya salah (harusnya ada tanda titik dua). Coba lagi."; TOKEN="" ;;
  esac
done
[ -n "$TOKEN" ] || die "Token kosong 3 kali — ulangi skrip ini bila token sudah siap."

mkdir -p "$HOME/.hermes"
ENV_FILE="$HOME/.hermes/.env"
touch "$ENV_FILE"
# Buang baris lama yang akan ditulis ulang, pertahankan baris lain.
grep -v -E '^(TELEGRAM_BOT_TOKEN|TELEGRAM_ALLOWED_USERS|OPENAI_API_KEY)=' "$ENV_FILE" > "$ENV_FILE.tmp" || true
mv "$ENV_FILE.tmp" "$ENV_FILE"
{
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN"
  printf 'TELEGRAM_ALLOWED_USERS=%s\n' "$TGID"
  printf 'OPENAI_API_KEY=sk-hermuse-lokal\n'
} >> "$ENV_FILE"
chmod 600 "$ENV_FILE"
log ".env ditulis (chmod 600). Token tidak ditampilkan di layar/log mana pun."

# --- 8. Nyalakan 9Router + gateway + watchdog ------------------------------
log "Langkah 8/8: menyalakan 9Router dan gateway..."
bash "$REPO_DIR/restart-9router.sh" || warn "restart-9router gagal."
for i in $(seq 1 15); do
  curl -s -m 4 -o /dev/null http://127.0.0.1:20128/dashboard && break
  sleep 2
done

cat > "$REPO_DIR/mulai-gateway.sh" <<'EOF'
#!/bin/bash
# Menyalakan gateway Telegram Hermes (detached) memakai perintah hermes resmi.
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$D"
setsid nohup hermes gateway run >> gateway.log 2>&1 < /dev/null &
echo "gateway dimulai (pid $!)"
EOF
chmod +x "$REPO_DIR/mulai-gateway.sh"

cat > "$REPO_DIR/jaga.sh" <<'EOF'
#!/bin/bash
# Watchdog lokal Hermuse: hidupkan lagi 9Router / gateway yang mati.
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
curl -s -m 8 -o /dev/null http://127.0.0.1:20128/dashboard || bash "$D/restart-9router.sh" > /dev/null 2>&1
ps aux | grep -q "[g]ateway.*run" || bash "$D/mulai-gateway.sh" > /dev/null 2>&1
EOF
chmod +x "$REPO_DIR/jaga.sh"

bash "$REPO_DIR/mulai-gateway.sh" || warn "gateway gagal dinyalakan — cek $REPO_DIR/gateway.log."

# Watchdog cron tiap 5 menit + sekali saat boot.
( crontab -l 2>/dev/null | grep -v 'Hermuse/jaga.sh' | grep -v 'Hermuse/mulai-gateway.sh'; \
  printf '*/5 * * * * %s/jaga.sh\n' "$REPO_DIR"; \
  printf '@reboot sleep 30 && %s/jaga.sh\n' "$REPO_DIR" ) | crontab -

log "Pemeriksaan akhir (doctor):"
bash "$REPO_DIR/scripts/doctor.sh" || warn "doctor menemukan FAIL — kirim hasilnya ke Zero."

# --- Ringkasan --------------------------------------------------------------
printf '\n=====================================================\n'
printf 'SELESAI. Ringkasan:\n'
if curl -s -m 4 -o /dev/null http://127.0.0.1:20128/dashboard; then
  printf '  9Router : JALAN di 127.0.0.1:20128\n'
else
  printf '  9Router : BELUM merespons — cek %s/9router.log\n' "$REPO_DIR"
fi
if ps aux | grep -q "[g]ateway.*run"; then
  printf '  Gateway : JALAN — coba kirim pesan ke bot ujimu di Telegram\n'
else
  printf '  Gateway : BELUM jalan — cek %s/gateway.log\n' "$REPO_DIR"
fi
if [ -n "$DASH_PW" ]; then
  printf '  Password dashboard 9Router (SIMPAN SEKARANG, hanya tampil sekali): %s\n' "$DASH_PW"
fi
printf '\nSISA SATU langkah otaknya (pilih satu):\n'
printf '  A) Tambah API key Gemini-mu sebagai koneksi di dashboard 9Router\n'
printf '     (dashboard hanya di 127.0.0.1 VPS — pakai port forwarding Termius), atau\n'
printf '  B) Otak instan via Nous Portal: hermes setup --portal\n'
printf '=====================================================\n'
