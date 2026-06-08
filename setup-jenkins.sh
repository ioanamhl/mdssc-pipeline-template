#!/usr/bin/env bash
# =============================================================================
#  MDSSC Pipeline Template — setup-jenkins.sh
#
#  Instalare automată Jenkins pentru integrarea MDSSC.
#  Detectează automat mediul și alege metoda de instalare:
#    - Docker disponibil  → Jenkins în container
#    - Ubuntu/Debian      → instalare nativă via apt
#
#  Utilizare:
#    chmod +x setup-jenkins.sh
#    ./setup-jenkins.sh
# =============================================================================

set -euo pipefail

# ── Culori ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${BOLD}${CYAN}▶ $1${NC}"; }

# ── Header ───────────────────────────────────────────────────────────────────
header() {
  echo ""
  echo -e "${BOLD}${CYAN}============================================================${NC}"
  echo -e "${BOLD}${CYAN}   MDSSC Pipeline Template — Jenkins Setup${NC}"
  echo -e "${BOLD}${CYAN}============================================================${NC}"
  echo ""
}

# ── Citire pipeline.config.yml ────────────────────────────────────────────────
read_config() {
  local key="$1"
  local default="${2:-}"
  if command -v yq &>/dev/null && [ -f "pipeline.config.yml" ]; then
    local val
    val=$(yq ".${key}" pipeline.config.yml 2>/dev/null || echo "")
    if [ -z "$val" ] || [ "$val" = "null" ]; then
      echo "$default"
    else
      echo "$val"
    fi
  else
    echo "$default"
  fi
}

# ── Plugin-uri necesare pentru MDSSC ─────────────────────────────────────────
JENKINS_PLUGINS=(
  "git"
  "workflow-aggregator"
  "pipeline-stage-view"
  "credentials-binding"
  "plain-credentials"
  "docker-workflow"
  "timestamper"
  "ws-cleanup"
  "ansicolor"
  "github"
  "github-branch-source"
  "nodejs"
  "pipeline-utility-steps"
)

# ── Verificare dependențe ─────────────────────────────────────────────────────
check_deps() {
  log_step "Verificare dependențe"
  local MISSING=()
  command -v curl &>/dev/null || MISSING+=("curl")
  command -v git  &>/dev/null || MISSING+=("git")

  if [ ${#MISSING[@]} -gt 0 ]; then
    log_error "Lipsesc: ${MISSING[*]}"
    log_error "Instalează-le și rulează scriptul din nou."
    exit 1
  fi

  if ! command -v yq &>/dev/null; then
    log_warn "yq nu e instalat — se folosesc valori default."
    log_warn "Pentru citire automată din pipeline.config.yml, instalează yq:"
    log_warn "  wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
    log_warn "  chmod +x /usr/local/bin/yq"
  fi

  log_ok "Dependențe OK"
}

# ── Detectare mod instalare ───────────────────────────────────────────────────
detect_mode() {
  log_step "Detectare mediu de instalare"

  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    DOCKER_AVAILABLE=true
    log_ok "Docker detectat ($(docker --version | cut -d' ' -f3 | tr -d ','))"
  else
    DOCKER_AVAILABLE=false
    log_info "Docker nu e disponibil"
  fi

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
    log_ok "OS detectat: ${PRETTY_NAME:-$ID}"
  else
    OS_ID="unknown"
  fi

  JENKINS_MODE=$(read_config "jenkins_mode" "docker")

  if [ "$DOCKER_AVAILABLE" = true ] || [ "$JENKINS_MODE" = "docker" ]; then
    INSTALL_MODE="docker"
    log_ok "Mod selectat: ${BOLD}Docker${NC}"
  elif [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    INSTALL_MODE="linux"
    log_ok "Mod selectat: ${BOLD}Linux nativ (apt)${NC}"
  else
    log_error "Docker nu e disponibil și OS-ul ($OS_ID) nu e suportat pentru instalare nativă."
    log_error "Instalează Docker și rulează scriptul din nou."
    exit 1
  fi
}

# ── Așteptare Jenkins ready ───────────────────────────────────────────────────
wait_for_jenkins() {
  local PORT="$1"
  local MAX_WAIT=120
  local WAITED=0

  log_info "Aștept Jenkins să pornească (max ${MAX_WAIT}s)..."
  while ! curl -sf "http://localhost:${PORT}/login" > /dev/null 2>&1; do
    sleep 3
    WAITED=$((WAITED + 3))
    echo -ne "  ${CYAN}⏳ ${WAITED}s...${NC}\r"
    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
      echo ""
      log_error "Jenkins nu a pornit în ${MAX_WAIT}s."
      log_error "Verifică logs: docker logs jenkins-${PROJECT_NAME}"
      exit 1
    fi
  done
  echo ""
  log_ok "Jenkins este online!"
}

# ── Creare job Jenkins ────────────────────────────────────────────────────────
create_jenkins_job() {
  local PORT="$1"
  local GITHUB_REPO="$2"
  local JOB_NAME="$3"

  cat > /tmp/jenkins-job.xml << XMLEOF
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>MDSSC Pipeline — ${JOB_NAME}</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
      <triggers>
        <com.cloudbees.jenkins.GitHubPushTrigger plugin="github">
          <spec></spec>
        </com.cloudbees.jenkins.GitHubPushTrigger>
      </triggers>
    </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>${GITHUB_REPO}</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
    </scm>
    <scriptPath>ci/Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
</flow-definition>
XMLEOF

  if curl -sf -X POST \
    "http://localhost:${PORT}/createItem?name=${JOB_NAME}" \
    --header "Content-Type: application/xml" \
    --data-binary @/tmp/jenkins-job.xml \
    2>/dev/null; then
    log_ok "Job '${JOB_NAME}' creat în Jenkins"
  else
    log_warn "Job-ul nu a putut fi creat automat — creează-l manual din UI"
  fi
}

# ── Instalare via Docker ──────────────────────────────────────────────────────
install_docker_mode() {
  log_step "Instalare Jenkins via Docker"

  PROJECT_NAME=$(read_config "project_name" "mdssc-project")
  JENKINS_PORT=$(read_config "jenkins_port" "8080")
  JENKINS_URL=$(read_config "jenkins_url" "http://localhost:${JENKINS_PORT}")
  GITHUB_REPO=$(read_config "github_repo" "")
  JOB_NAME=$(read_config "jenkins_job" "${PROJECT_NAME}-pipeline")

  # Extrage host-ul din jenkins_url
  JENKINS_HOST=$(echo "$JENKINS_URL" | sed 's|http[s]*://||' | cut -d: -f1 | cut -d/ -f1)

  # Avertisment localhost
  if [[ "$JENKINS_HOST" == "localhost" || "$JENKINS_HOST" == "127.0.0.1" ]]; then
    echo ""
    log_warn "═══════════════════════════════════════════════════════"
    log_warn "  jenkins_url e setat pe localhost."
    log_warn "  GitHub Actions NU poate triggeriza un Jenkins local."
    log_warn ""
    log_warn "  Opțiuni:"
    log_warn "  1. Rulează pe un VPS cu IP public (recomandat)"
    log_warn "     → schimbă jenkins_url în pipeline.config.yml"
    log_warn "  2. Folosește ngrok pentru un tunel temporar:"
    log_warn "     ngrok http ${JENKINS_PORT}"
    log_warn "     → pune URL-ul ngrok în jenkins_url"
    log_warn "═══════════════════════════════════════════════════════"
    echo ""
  fi

  JENKINS_HOME="$HOME/.jenkins-data/${PROJECT_NAME}"
  mkdir -p "$JENKINS_HOME"
  log_ok "Date Jenkins: $JENKINS_HOME"

  # Verifică container existent
  if docker ps -a --format '{{.Names}}' | grep -q "^jenkins-${PROJECT_NAME}$"; then
    log_warn "Containerul jenkins-${PROJECT_NAME} există deja."
    echo -ne "  ${YELLOW}Vrei să îl recreezi? (y/N):${NC} "
    read -r RECREATE
    if [[ "$RECREATE" =~ ^[Yy]$ ]]; then
      docker stop "jenkins-${PROJECT_NAME}" 2>/dev/null || true
      docker rm   "jenkins-${PROJECT_NAME}" 2>/dev/null || true
      log_ok "Container vechi șters"
    else
      log_info "Folosesc containerul existent."
      show_final_info "$JENKINS_URL" "$JENKINS_PORT" "$JOB_NAME" ""
      return
    fi
  fi

  # Pornire Jenkins
  log_step "Pornire container Jenkins"
  docker run -d \
    --name "jenkins-${PROJECT_NAME}" \
    --restart unless-stopped \
    -p "${JENKINS_PORT}:8080" \
    -p "50000:50000" \
    -v "${JENKINS_HOME}:/var/jenkins_home" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false" \
    --user root \
    jenkins/jenkins:lts-jdk17 > /dev/null
  log_ok "Container Jenkins pornit"

  wait_for_jenkins "$JENKINS_PORT"

  # Instalare plugin-uri
  log_step "Instalare plugin-uri Jenkins (${#JENKINS_PLUGINS[@]} plugin-uri)"
  docker exec "jenkins-${PROJECT_NAME}" \
    jenkins-plugin-cli --plugins "${JENKINS_PLUGINS[@]}" 2>&1 | \
    grep -E "^(Installing|Done|Error)" || true

  log_info "Restart Jenkins pentru activare plugin-uri..."
  docker restart "jenkins-${PROJECT_NAME}" > /dev/null
  sleep 10
  wait_for_jenkins "$JENKINS_PORT"
  log_ok "Plugin-uri instalate"

  # Creare job
  if [ -n "$GITHUB_REPO" ]; then
    log_step "Creare job Jenkins"
    create_jenkins_job "$JENKINS_PORT" "$GITHUB_REPO" "$JOB_NAME"
  else
    log_warn "github_repo nu e setat în pipeline.config.yml — job-ul Jenkins trebuie creat manual"
  fi

  show_final_info "$JENKINS_URL" "$JENKINS_PORT" "$JOB_NAME" ""
}

# ── Instalare nativă Linux ────────────────────────────────────────────────────
install_linux_mode() {
  log_step "Instalare Jenkins pe Linux (apt)"

  if [ "$EUID" -ne 0 ]; then
    log_error "Instalarea nativă necesită sudo. Rulează: sudo ./setup-jenkins.sh"
    exit 1
  fi

  PROJECT_NAME=$(read_config "project_name" "mdssc-project")
  JENKINS_PORT=$(read_config "jenkins_port" "8080")
  JENKINS_URL=$(read_config "jenkins_url" "http://$(hostname -I | awk '{print $1}'):${JENKINS_PORT}")
  GITHUB_REPO=$(read_config "github_repo" "")
  JOB_NAME=$(read_config "jenkins_job" "${PROJECT_NAME}-pipeline")

  # Java
  log_step "Instalare Java 17"
  if java -version 2>&1 | grep -qE "17|21"; then
    log_ok "Java deja instalat"
  else
    apt-get update -qq
    apt-get install -y -qq openjdk-17-jdk
    log_ok "Java 17 instalat"
  fi

  # Jenkins repo
  log_step "Adăugare repository Jenkins"
  curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
    | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
  echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
    https://pkg.jenkins.io/debian-stable binary/" \
    | tee /etc/apt/sources.list.d/jenkins.list > /dev/null

  # Instalare
  log_step "Instalare Jenkins"
  apt-get update -qq
  apt-get install -y -qq jenkins

  # Port custom
  if [ "$JENKINS_PORT" != "8080" ]; then
    sed -i "s/HTTP_PORT=8080/HTTP_PORT=${JENKINS_PORT}/" /etc/default/jenkins
    log_ok "Port configurat: $JENKINS_PORT"
  fi

  # Pornire
  log_step "Pornire serviciu Jenkins"
  systemctl enable jenkins
  systemctl start jenkins
  log_ok "Serviciu Jenkins pornit"

  wait_for_jenkins "$JENKINS_PORT"

  # Plugin-uri via CLI
  log_step "Instalare plugin-uri"
  JENKINS_CLI="/tmp/jenkins-cli.jar"
  curl -fsSL "http://localhost:${JENKINS_PORT}/jnlpJars/jenkins-cli.jar" -o "$JENKINS_CLI"
  INITIAL_PASSWORD=$(cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || echo "")

  for plugin in "${JENKINS_PLUGINS[@]}"; do
    java -jar "$JENKINS_CLI" \
      -s "http://localhost:${JENKINS_PORT}" \
      -auth "admin:${INITIAL_PASSWORD}" \
      install-plugin "$plugin" -deploy 2>/dev/null && \
      log_ok "  Plugin: $plugin" || \
      log_warn "  Plugin skipped: $plugin"
  done

  systemctl restart jenkins
  wait_for_jenkins "$JENKINS_PORT"
  log_ok "Plugin-uri instalate"

  # Creare job
  if [ -n "$GITHUB_REPO" ]; then
    log_step "Creare job Jenkins"
    create_jenkins_job "$JENKINS_PORT" "$GITHUB_REPO" "$JOB_NAME"
  fi

  show_final_info "$JENKINS_URL" "$JENKINS_PORT" "$JOB_NAME" "$INITIAL_PASSWORD"
}

# ── Info finale ───────────────────────────────────────────────────────────────
show_final_info() {
  local JENKINS_URL="$1"
  local JENKINS_PORT="$2"
  local JOB_NAME="$3"
  local INITIAL_PASSWORD="$4"

  echo ""
  echo -e "${BOLD}${GREEN}============================================================${NC}"
  echo -e "${BOLD}${GREEN}   Jenkins instalat cu succes! ✓${NC}"
  echo -e "${BOLD}${GREEN}============================================================${NC}"
  echo ""
  echo -e "  ${BOLD}URL Jenkins:${NC}   ${JENKINS_URL}"
  echo -e "  ${BOLD}Job creat:${NC}     ${JOB_NAME}"
  echo ""
  if [ -n "$INITIAL_PASSWORD" ]; then
    echo -e "  ${BOLD}${YELLOW}Parolă inițială admin:${NC} ${INITIAL_PASSWORD}"
    echo ""
  fi
  echo -e "  ${BOLD}Pași următori:${NC}"
  echo -e "  ${CYAN}1.${NC} Deschide ${JENKINS_URL} în browser"
  echo -e "  ${CYAN}2.${NC} Adaugă credențialele MDSSC în Jenkins:"
  echo -e "     Manage Jenkins → Credentials → Global → Add:"
  echo -e "     • Kind: Secret text"
  echo -e "     • ID: mdssc-api-key"
  echo -e "     • Secret: API key-ul tău MDSSC"
  echo -e "  ${CYAN}3.${NC} Adaugă secretele Jenkins în GitHub repo:"
  echo -e "     Settings → Secrets → Actions:"
  echo -e "     • JENKINS_VPS_URL  = ${JENKINS_URL}"
  echo -e "     • JENKINS_USER     = admin"
  echo -e "     • JENKINS_API_TOKEN = (generat din Jenkins → User → Configure)"
  echo -e "  ${CYAN}4.${NC} Fă un push pe main și urmărește pipeline-ul în GitHub Actions"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  header
  check_deps
  detect_mode

  case "$INSTALL_MODE" in
    docker) install_docker_mode ;;
    linux)  install_linux_mode  ;;
  esac
}

main "$@"