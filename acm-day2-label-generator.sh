#!/usr/bin/env bash
#
# ACM Day-2 policy overlay analizcisi ve managed cluster label üreticisi.
#
# Kullanım:
#   ./acm-day2-label-generator.sh
#   ./acm-day2-label-generator.sh --repo /path/to/acm-sot
#   ./acm-day2-label-generator.sh --repo https://github.com/example/acm-sot.git
#   ACM_SOT_REPO=/path/to/acm-sot ./acm-day2-label-generator.sh
#
# Script, whiptail veya dialog varsa menülü bir arayüz kullanır. İkisi de
# yoksa aynı akış standart read komutları ile devam eder.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
REPO_PATH="${ACM_SOT_REPO:-}"
CLONE_DIR=""
OUTPUT_FILE=""
UI_TOOL=""
CLUSTER_NAME=""
GLOBAL_ENV=""

# Gerçek repo bulunamadığında lokal testler için kullanılan örnek envanter.
# Format: policy|overlay. Base-only policy'ler ayrıca MOCK_BASE_POLICIES içinde.
MOCK_OVERLAYS=(
  "alertmanager|iisadmins"
  "alertmanager|ocpadmins"
  "etcdbackup|prod"
  "etcdbackup|test"
  "huaweicsi|dmz-hypermetro"
  "huaweicsi|odm-dmz-hypermetro"
  "huaweicsi|odm-standalone"
  "huaweicsi|prod-hypermetro"
  "huaweicsi|prod-standalone"
  "huaweicsi|test-standalone"
  "logging6|prod"
  "logging6|test"
)
MOCK_BASE_POLICIES=("kubeletmaster" "monitoring")

POLICIES=()
OVERLAY_POLICIES=()
OVERLAYS=()
BASE_POLICIES=()
SELECTED_POLICIES=()
SELECTED_VALUES=()
LABEL_COMMANDS=()

# Scriptin kullanım seçeneklerini ve örnek komutlarını ekrana basar.
usage() {
  cat <<EOF
Kullanım: $SCRIPT_NAME [--repo PATH_OR_GIT_URL] [--output /path/to/file]

Seçenekler:
  --repo VALUE      Yerel acm-sot yolu veya Git repo URL'si (varsayılan: ACM_SOT_REPO)
  --output PATH     Üretilen oc komutlarını dosyaya kaydet
  -h, --help        Bu yardımı göster

Repo verilmezse örnek mock envanter kullanılır.
EOF
}

# Hata mesajını stderr'e yazıp scripti kontrollü şekilde sonlandırır.
die() {
  printf 'Hata: %s\n' "$*" >&2
  exit 1
}

# Verilen değerin değişken sayıda öğe içeren listede bulunup bulunmadığını kontrol eder.
contains() {
  local wanted="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$wanted" ]] && return 0
  done
  return 1
}

# Komut satırı seçeneklerini ayrıştırır ve ilgili global değişkenleri doldurur.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || die "--repo bir yol bekler."
        REPO_PATH="$2"
        shift 2
        ;;
      --output)
        [[ $# -ge 2 ]] || die "--output bir dosya yolu bekler."
        OUTPUT_FILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Bilinmeyen seçenek: $1"
        ;;
    esac
  done
}

# Kullanılabilir terminal arayüzünü öncelik sırasıyla whiptail, dialog veya read olarak belirler.
select_ui_tool() {
  if command -v whiptail >/dev/null 2>&1; then
    UI_TOOL="whiptail"
  elif command -v dialog >/dev/null 2>&1; then
    UI_TOOL="dialog"
  else
    UI_TOOL="read"
  fi
}

# Kullanılan arayüz aracına göre kullanıcıdan tek satırlık metin girdisi alır.
ui_input() {
  local prompt="$1"
  local default_value="${2:-}"
  if [[ "$UI_TOOL" == "whiptail" ]]; then
    whiptail --inputbox "$prompt" 10 70 "$default_value" 3>&1 1>&2 2>&3
  elif [[ "$UI_TOOL" == "dialog" ]]; then
    dialog --inputbox "$prompt" 10 70 "$default_value" 3>&1 1>&2 2>&3
  else
    local answer
    read -r -p "$prompt [$default_value]: " answer
    printf '%s\n' "${answer:-$default_value}"
  fi
}

# Kullanıcıya seçenek menüsü gösterir ve seçilen seçeneğin indeksini döndürür.
ui_menu() {
  local prompt="$1"
  shift
  local options=("$@")
  local answer
  local index=1

  if [[ "$UI_TOOL" == "whiptail" || "$UI_TOOL" == "dialog" ]]; then
    local args=("$prompt" 20 80 "${#options[@]}")
    local option label
    for option in "${options[@]}"; do
      label="$option"
      args+=("$index" "$label")
      index=$((index + 1))
    done
    if [[ "$UI_TOOL" == "whiptail" ]]; then
      whiptail --menu "${args[@]}" 3>&1 1>&2 2>&3
    else
      dialog --menu "${args[@]}" 3>&1 1>&2 2>&3
    fi
  else
    printf '\n%s\n' "$prompt" >&2
    index=1
    for option in "${options[@]}"; do
      printf '  %d) %s\n' "$index" "$option" >&2
      index=$((index + 1))
    done
    while true; do
      read -r -p 'Seçiminiz: ' answer
      if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#options[@]} )); then
        printf '%s\n' "$answer"
        return 0
      fi
      printf 'Geçersiz seçim. 1-%d arasında bir değer girin.\n' "${#options[@]}" >&2
    done
  fi
}

# Gerçek acm-sot repo bulunamadığında test amacıyla örnek policy envanterini yükler.
load_mock_inventory() {
  local entry policy overlay
  for entry in "${MOCK_OVERLAYS[@]}"; do
    policy="${entry%%|*}"
    overlay="${entry#*|}"
    OVERLAY_POLICIES+=("$policy")
    OVERLAYS+=("$overlay")
    if [[ ${#POLICIES[@]:-0} -eq 0 ]] || ! contains "$policy" "${POLICIES[@]-}"; then
      POLICIES+=("$policy")
    fi
  done
  for policy in "${MOCK_BASE_POLICIES[@]}"; do
    BASE_POLICIES+=("$policy")
    if ! contains "$policy" "${POLICIES[@]-}"; then
      POLICIES+=("$policy")
    fi
  done
}

# Gerçek repo içindeki resources/<policy>/overlays/<overlay> ve
# resources/<policy>/base dizinlerini tarayıp policy envanterini oluşturur.
load_repo_inventory() {
  local resource_dir policy overlays_dir overlay base_dir
  local inventory_file
  inventory_file="$(mktemp "${TMPDIR:-/tmp}/acm-sot-inventory.XXXXXX")"

  find "$REPO_PATH/resources" -mindepth 2 -maxdepth 4 -type d -print >"$inventory_file"
  while IFS= read -r resource_dir; do
    case "$resource_dir" in
      */resources/*/overlays)
        policy="${resource_dir%/overlays}"
        policy="${policy##*/}"
        while IFS= read -r -d '' overlay_dir; do
          overlay="${overlay_dir##*/}"
          OVERLAY_POLICIES+=("$policy")
          OVERLAYS+=("$overlay")
          if [[ ${#POLICIES[@]:-0} -eq 0 ]] || ! contains "$policy" "${POLICIES[@]-}"; then
            POLICIES+=("$policy")
          fi
        done < <(find "$resource_dir" -mindepth 1 -maxdepth 1 -type d -print0)
        ;;
      */resources/*/base)
        base_dir="${resource_dir%/base}"
        policy="${base_dir##*/}"
        BASE_POLICIES+=("$policy")
        if ! contains "$policy" "${POLICIES[@]-}"; then
          POLICIES+=("$policy")
        fi
        ;;
    esac
  done <"$inventory_file"
  rm -f "$inventory_file"
}

# Repo URL'sini geçici bir checkout'a indirir veya yerel repo yolunu doğrular.
prepare_repo() {
  if [[ -z "$REPO_PATH" ]]; then
    return 0
  fi

  if [[ -d "$REPO_PATH/resources" ]]; then
    return 0
  fi

  if [[ "$REPO_PATH" =~ ^[[:alpha:]][[:alnum:]+.-]*:// || "$REPO_PATH" =~ ^git@ ]]; then
    CLONE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/acm-sot.XXXXXX")"
    trap 'rm -rf "$CLONE_DIR"' EXIT HUP INT TERM
    printf 'Git repo klonlanıyor: %s\n' "$REPO_PATH"
    git clone --depth 1 "$REPO_PATH" "$CLONE_DIR" >/dev/null || die "Git repo klonlanamadı: $REPO_PATH"
    REPO_PATH="$CLONE_DIR"
    return 0
  fi

  die "Repo yolu bulunamadı veya resources dizini yok: $REPO_PATH"
}

# Gerçek repo kullanılabiliyorsa repo envanterini, repo verilmediyse mock envanteri yükler.
load_inventory() {
  prepare_repo
  if [[ -n "$REPO_PATH" ]]; then
    load_repo_inventory
    [[ ${#POLICIES[@]:-0} -gt 0 ]] || die "Repo içinde resources altında policy bulunamadı."
    printf 'Repo envanteri okundu: %s\n' "$REPO_PATH"
  else
    load_mock_inventory
    printf 'Bilgi: Gerçek acm-sot bulunamadı; mock envanter kullanılıyor.\n'
  fi
}

# Belirli bir policy için tanımlı overlay adlarını listeler.
policy_overlays() {
  local policy="$1" i
  for ((i = 0; i < ${#OVERLAY_POLICIES[@]}; i++)); do
    [[ "${OVERLAY_POLICIES[$i]}" == "$policy" ]] && printf '%s\n' "${OVERLAYS[$i]}"
  done
}

# Policy için base veya otomatik ortam eşleşmesini seçer; gerekirse menü açar.
choose_overlay() {
  local policy="$1"
  local overlays=()
  local overlay selected_index candidate
  while IFS= read -r overlay; do
    [[ -n "$overlay" ]] && overlays+=("$overlay")
  done < <(policy_overlays "$policy")

  if [[ ${#overlays[@]:-0} -eq 0 ]]; then
    SELECTED_POLICIES+=("$policy")
    SELECTED_VALUES+=("base")
    return 0
  fi

  # Ortamla birebir eşleşen overlay varsa ek soru sormadan onu seç.
  if contains "$GLOBAL_ENV" "${overlays[@]}"; then
    SELECTED_POLICIES+=("$policy")
    SELECTED_VALUES+=("$GLOBAL_ENV")
    return 0
  fi

  if [[ ${#overlays[@]:-0} -eq 1 ]]; then
    SELECTED_POLICIES+=("$policy")
    SELECTED_VALUES+=("${overlays[0]}")
    return 0
  fi

  local menu_options=()
  for candidate in "${overlays[@]}"; do
    menu_options+=("$candidate")
  done
  selected_index="$(ui_menu "$policy policy overlay seçin" "${menu_options[@]}")"
  SELECTED_POLICIES+=("$policy")
  SELECTED_VALUES+=("${overlays[$((selected_index - 1))]}")
}

# Kullanıcı seçimlerini oc label managedcluster komutlarına dönüştürür.
build_commands() {
  local i policy value
  for ((i = 0; i < ${#SELECTED_POLICIES[@]}; i++)); do
    policy="${SELECTED_POLICIES[$i]}"
    value="${SELECTED_VALUES[$i]}"
    if [[ "$value" == "base" ]]; then
      LABEL_COMMANDS+=("oc label managedcluster $CLUSTER_NAME sot/$policy=base --overwrite")
    else
      LABEL_COMMANDS+=("oc label managedcluster $CLUSTER_NAME sot/$policy=overlays-$value --overwrite")
    fi
  done
}

# Üretilen komutları terminale yazdırır ve istenirse dosyaya kaydeder.
write_output() {
  local command
  printf '\nÜretilen label komutları:\n'
  for command in "${LABEL_COMMANDS[@]}"; do
    printf '%s\n' "$command"
  done
  if [[ -n "$OUTPUT_FILE" ]]; then
    : >"$OUTPUT_FILE"
    for command in "${LABEL_COMMANDS[@]}"; do
      printf '%s\n' "$command" >>"$OUTPUT_FILE"
    done
    printf '\nKomutlar kaydedildi: %s\n' "$OUTPUT_FILE"
  fi
}

# Scriptin ana akışını yönetir: argüman, envanter, kullanıcı seçimleri ve çıktı.
main() {
  parse_args "$@"
  select_ui_tool
  load_inventory

  CLUSTER_NAME="$(ui_input 'Managed cluster adını girin')"
  [[ -n "$CLUSTER_NAME" ]] || die 'Cluster adı boş bırakılamaz.'
  local environment_index
  environment_index="$(ui_menu 'Kurulacak cluster ortamı nedir?' test prod)"
  case "$environment_index" in
    1) GLOBAL_ENV="test" ;;
    2) GLOBAL_ENV="prod" ;;
    *) die 'Geçersiz ortam seçimi.' ;;
  esac

  local policy
  for policy in "${POLICIES[@]}"; do
    choose_overlay "$policy"
  done
  build_commands
  write_output
}

main "$@"