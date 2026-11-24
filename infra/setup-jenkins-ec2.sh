#!/usr/bin/env bash
# Bootstraps Jenkins CI for this repository on an Ubuntu EC2 instance.
#
#   curl -fsSL https://raw.githubusercontent.com/izzaeiman/Assignment/main/infra/setup-jenkins-ec2.sh \
#     | sudo bash -s -- <ADMIN_IP>
#
# - OpenJDK 21, Git, Jenkins LTS (enabled at boot), plugins: git, github, workflow-aggregator, timestamper
# - Jenkins listens on 127.0.0.1:8080 only; Caddy serves HTTPS on 443 with a Let's Encrypt certificate
#   * /github-webhook/ is reachable from anywhere (GitHub)
#   * the dashboard is reachable only from ADMIN_IP
# - No setup wizard: an 'admin' user is created with a random password stored in
#   /var/lib/jenkins/secrets/admin-password (root/jenkins only; never printed)
# - Creates the pipeline job "Assignment-CI" (Pipeline from SCM, Jenkinsfile, GitHub push trigger)
# Idempotent: safe to re-run. Existing Jenkins users/security are left alone.
set -euo pipefail

ADMIN_IP="${1:?usage: setup-jenkins-ec2.sh <ADMIN_IP> [BRANCH]}"
BRANCH="${2:-main}"
REPO_URL="https://github.com/izzaeiman/Assignment.git"
JOB_NAME="Assignment-CI"
JH=/var/lib/jenkins
export DEBIAN_FRONTEND=noninteractive

log() { echo -e "\n=== $* ==="; }

# ---------- public hostname (sslip.io maps a.b.c.d.sslip.io -> a.b.c.d) ----------
TOKEN=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
PUBLIC_IP=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
HOST="${PUBLIC_IP//./-}.sslip.io"
log "Public IP $PUBLIC_IP -> https://$HOST/"

# ---------- swap on small instances (Jenkins needs ~1 GB) ----------
if [ "$(awk '/MemTotal/{print $2}' /proc/meminfo)" -lt 2000000 ] && ! swapon --show | grep -q /swapfile; then
  log "Adding 2G swap"
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ---------- packages ----------
log "Installing OpenJDK 21, Git"
apt-get update -qq
apt-get install -y -qq openjdk-21-jdk-headless git curl fontconfig gnupg debian-keyring debian-archive-keyring apt-transport-https >/dev/null
JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")

if ! dpkg -s jenkins >/dev/null 2>&1; then
  log "Installing Jenkins LTS"
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key -o /etc/apt/keyrings/jenkins-keyring.asc
  echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
    > /etc/apt/sources.list.d/jenkins.list
  apt-get update -qq
  apt-get install -y -qq jenkins >/dev/null
else
  log "Jenkins already installed ($(dpkg-query -W -f='${Version}' jenkins)) - keeping it"
fi
systemctl stop jenkins || true

if ! dpkg -s caddy >/dev/null 2>&1; then
  log "Installing Caddy"
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
fi

# ---------- Jenkins service: localhost only, no wizard, Java 21 ----------
log "Configuring Jenkins service"
mkdir -p /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/override.conf <<EOF
[Service]
Environment="JAVA_HOME=$JAVA_HOME"
Environment="JENKINS_LISTEN_ADDRESS=127.0.0.1"
Environment="JENKINS_PORT=8080"
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false"
EOF
systemctl daemon-reload

# ---------- plugins ----------
log "Installing Jenkins plugins"
PM=/opt/jenkins-plugin-manager.jar
if [ ! -f "$PM" ]; then
  URL=$(curl -fsSL https://api.github.com/repos/jenkinsci/plugin-installation-manager-tool/releases/latest \
        | grep -o '"browser_download_url": *"[^"]*\.jar"' | head -1 | cut -d'"' -f4)
  curl -fsSL "$URL" -o "$PM"
fi
mkdir -p "$JH/plugins"
java -jar "$PM" --war /usr/share/java/jenkins.war --plugin-download-directory "$JH/plugins" \
  --plugins git github workflow-aggregator timestamper 2>&1 | tail -3

# ---------- bootstrap config + admin secret ----------
mkdir -p "$JH/secrets" "$JH/init.groovy.d"
if [ ! -s "$JH/secrets/admin-password" ]; then
  umask 077; head -c 24 /dev/urandom | base64 | tr -d '/+=' > "$JH/secrets/admin-password"; umask 022
fi
chmod 600 "$JH/secrets/admin-password"
cat > "$JH/bootstrap.properties" <<EOF
jobName=$JOB_NAME
repoUrl=$REPO_URL
branch=*/$BRANCH
jenkinsUrl=https://$HOST/
javaHome=$JAVA_HOME
EOF

cat > "$JH/init.groovy.d/10-bootstrap.groovy" <<'GROOVY'
import jenkins.model.*
import hudson.model.*
import hudson.security.*
import hudson.plugins.git.*
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition
import org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty
import com.cloudbees.jenkins.GitHubPushTrigger

def j = Jenkins.get()
def home = j.getRootDir()
def cfg = new Properties()
new File(home, 'bootstrap.properties').withInputStream { cfg.load(it) }
def pw = new File(home, 'secrets/admin-password').text.trim()

// --- security: create admin only if nobody is configured; replace wizard's temporary password ---
def realm = j.getSecurityRealm()
def initial = new File(home, 'secrets/initialAdminPassword')
if (!(realm instanceof HudsonPrivateSecurityRealm) || realm.getAllUsers().isEmpty()) {
  def r = new HudsonPrivateSecurityRealm(false)
  r.createAccount('admin', pw)
  j.setSecurityRealm(r)
  def s = new FullControlOnceLoggedInAuthorizationStrategy()
  s.setAllowAnonymousRead(false)
  j.setAuthorizationStrategy(s)
  println '[bootstrap] admin user created'
} else if (initial.exists()) {
  def u = User.getById('admin', false)
  if (u != null) { u.addProperty(HudsonPrivateSecurityRealm.Details.fromPlainPassword(pw)); u.save() }
  initial.delete()
  println '[bootstrap] replaced setup-wizard admin password'
}

// --- URL + JDK 21 tool ---
def loc = JenkinsLocationConfiguration.get(); loc.setUrl(cfg.jenkinsUrl); loc.save()
def jdkDesc = j.getDescriptorByType(JDK.DescriptorImpl)
jdkDesc.setInstallations(new JDK('jdk21', cfg.javaHome)); jdkDesc.save()

// --- pipeline job ---
def job = j.getItem(cfg.jobName)
if (job == null) {
  job = j.createProject(WorkflowJob, cfg.jobName)
  def scm = new GitSCM(GitSCM.createRepoList(cfg.repoUrl, null), [new BranchSpec(cfg.branch)], null, null, [])
  def defn = new CpsScmFlowDefinition(scm, 'Jenkinsfile')
  defn.setLightweight(true)
  job.setDefinition(defn)
  job.setDescription('Compiles and runs MatrixMultiplication.java on every GitHub push (webhook).')
  println "[bootstrap] created job ${cfg.jobName}"
}
job.removeProperty(PipelineTriggersJobProperty)
job.addProperty(new PipelineTriggersJobProperty([new GitHubPushTrigger()]))
job.save()
j.save()
GROOVY
chown -R jenkins:jenkins "$JH"

# ---------- Caddy reverse proxy ----------
log "Configuring Caddy (HTTPS)"
cat > /etc/caddy/Caddyfile <<EOF
$HOST {
	encode gzip
	@webhook path /github-webhook /github-webhook/*
	handle @webhook {
		reverse_proxy 127.0.0.1:8080
	}
	@admin remote_ip $ADMIN_IP
	handle @admin {
		reverse_proxy 127.0.0.1:8080
	}
	handle {
		respond "Forbidden" 403
	}
}
EOF
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

systemctl enable --now jenkins >/dev/null
systemctl enable caddy >/dev/null && systemctl restart caddy

log "Waiting for Jenkins"
for i in $(seq 1 90); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/login || true)
  [ "$code" = "200" ] && break; sleep 2
done

log "VERIFICATION"
echo "OS:        $(lsb_release -ds)"
echo "Java:      $(java -version 2>&1 | head -1)"
echo "javac:     $(javac -version 2>&1)"
echo "Git:       $(git --version)"
echo "Jenkins:   $(dpkg-query -W -f='${Version}' jenkins)  active=$(systemctl is-active jenkins) enabled=$(systemctl is-enabled jenkins)"
echo "Caddy:     $(caddy version | cut -d' ' -f1)  active=$(systemctl is-active caddy) enabled=$(systemctl is-enabled caddy)"
echo "Listening: $(ss -ltnp | awk 'NR>1{print $4}' | grep -E ':(8080|80|443)$' | tr '\n' ' ')"
echo "Login page (local): HTTP $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/login)"
echo "Plugins:   $(ls $JH/plugins/*.jpi 2>/dev/null | xargs -n1 basename | sed 's/.jpi$//' | grep -xE 'git|github|workflow-aggregator|timestamper|workflow-cps|pipeline-model-definition' | tr '\n' ' ')"
echo "Job:       $(test -f $JH/jobs/$JOB_NAME/config.xml && echo "$JOB_NAME OK" || echo MISSING)"
journalctl -u jenkins --no-pager | grep '\[bootstrap\]' | tail -3 || true
sleep 5
echo "Webhook (public HTTPS, GET expects 405): HTTP $(curl -s -o /dev/null -w '%{http_code}' https://$HOST/github-webhook/ || echo FAIL)"
echo "Webhook URL: https://$HOST/github-webhook/"
echo "Admin password: sudo cat $JH/secrets/admin-password   (user: admin)"
