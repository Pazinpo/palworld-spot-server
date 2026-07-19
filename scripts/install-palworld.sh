#!/bin/bash
# Palworld 전용 서버 설치/부팅 스크립트 (EC2 User Data로 실행됨)
#
# - Ubuntu 22.04 기준. SteamCMD 실행을 위해 32bit 멀티립 패키지가 필요하다.
# - 세이브 데이터 EBS 볼륨을 자기 자신에게 붙이고(멱등), 게임 설치 경로 자체를
#   그 볼륨 위에 두어 스팟->온디맨드 교체 시 재다운로드 없이 그대로 이어서 뜬다.
# - PalWorldSettings.ini는 최초 부팅 시 1회만 생성한다. 이후 설정 변경은
#   인스턴스에 SSM Session Manager로 접속해서 직접 편집한다 (재부팅해도 유지됨).
set -euxo pipefail
exec > >(tee -a /var/log/palworld-install.log) 2>&1

# ---- Terraform 템플릿 변수 ----
DATA_VOLUME_ID="${data_volume_id}"
DEVICE_NAME="${data_volume_device}"
SERVER_NAME="${server_name}"
SERVER_DESCRIPTION="${server_description}"
SERVER_PASSWORD="${server_password}"
ADMIN_PASSWORD="${admin_password}"
MAX_PLAYERS="${max_players}"
# --------------------------------

MOUNT_POINT=/mnt/palworld-data
GAME_DIR="$MOUNT_POINT/Palworld"

wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    sleep 2
  done
}

# ---- IMDSv2 ----
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

wait_for_apt
apt-get update -y
apt-get install -y curl unzip jq fuse

# ---- AWS CLI v2 ----
if ! command -v aws >/dev/null 2>&1; then
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
fi

# ---- SteamCMD용 32bit 의존성 ----
dpkg --add-architecture i386
wait_for_apt
apt-get update -y
apt-get install -y software-properties-common
add-apt-repository -y multiverse || true
wait_for_apt
apt-get update -y
apt-get install -y lib32gcc-s1 lib32stdc++6 ca-certificates locales

# ---- 세이브 데이터 EBS 볼륨 attach + mount (멱등) ----
# 최초 스팟 인스턴스는 이 스크립트가 직접 자신에게 붙이고,
# Lambda가 대체 기동한 온디맨드 인스턴스는 Lambda가 먼저 붙여주므로
# 아래 attach-volume 호출은 "이미 붙어있음" 에러가 나며 아무 동작도 하지 않는다.
aws ec2 attach-volume \
  --volume-id "$DATA_VOLUME_ID" \
  --instance-id "$INSTANCE_ID" \
  --device "$DEVICE_NAME" \
  --region "$REGION" || true

VOLUME_ID_NODASH=$(echo "$DATA_VOLUME_ID" | sed 's/-//')
DEVICE_LINK="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$VOLUME_ID_NODASH"

for i in $(seq 1 60); do
  if [ -e "$DEVICE_LINK" ]; then
    break
  fi
  sleep 2
done

if [ ! -e "$DEVICE_LINK" ]; then
  echo "ERROR: data volume device did not appear at $DEVICE_LINK" >&2
  exit 1
fi

REAL_DEVICE=$(readlink -f "$DEVICE_LINK")

if ! blkid "$REAL_DEVICE" >/dev/null 2>&1; then
  mkfs.ext4 "$REAL_DEVICE"
fi

mkdir -p "$MOUNT_POINT"
mountpoint -q "$MOUNT_POINT" || mount "$REAL_DEVICE" "$MOUNT_POINT"

FS_UUID=$(blkid -s UUID -o value "$REAL_DEVICE")
grep -q "$FS_UUID" /etc/fstab || echo "UUID=$FS_UUID $MOUNT_POINT ext4 defaults,nofail 0 2" >>/etc/fstab

# ---- 스왑 (팰월드는 CPU/메모리 사용량이 커서 OOM 방지용 안전장치) ----
if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile none swap sw 0 0" >>/etc/fstab
fi

# ---- steam 실행 유저 ----
if ! id -u steam >/dev/null 2>&1; then
  useradd -m -s /bin/bash steam
fi
chown -R steam:steam "$MOUNT_POINT"

# ---- SteamCMD 설치 + 팰월드 전용 서버 (App ID 2394010) ----
mkdir -p /home/steam/steamcmd
chown steam:steam /home/steam/steamcmd

if [ ! -f /home/steam/steamcmd/steamcmd.sh ]; then
  su - steam -c "curl -sqL 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz' | tar zxvf - -C /home/steam/steamcmd"
fi

su - steam -c "/home/steam/steamcmd/steamcmd.sh +force_install_dir $GAME_DIR +login anonymous +app_update 2394010 validate +quit"

# ---- 서버 설정 파일 (최초 1회만 생성) ----
CONFIG_DIR="$GAME_DIR/Pal/Saved/Config/LinuxServer"
mkdir -p "$CONFIG_DIR"

if [ ! -f "$CONFIG_DIR/PalWorldSettings.ini" ]; then
  cat >"$CONFIG_DIR/PalWorldSettings.ini" <<EOF
[/Script/Pal.PalGameWorldSettings]
OptionSettings=(ServerName="$SERVER_NAME",ServerDescription="$SERVER_DESCRIPTION",AdminPassword="$ADMIN_PASSWORD",ServerPassword="$SERVER_PASSWORD",ServerPlayerMaxNum=$MAX_PLAYERS,PublicPort=8211,RCONEnabled=True,RCONPort=25575,RESTAPIEnabled=True,RESTAPIPort=8212,bIsMultiplay=True)
EOF
fi

chown -R steam:steam "$GAME_DIR"

# ---- systemd 서비스 ----
cat >/etc/systemd/system/palworld.service <<EOF
[Unit]
Description=Palworld Dedicated Server
After=network.target

[Service]
Type=simple
User=steam
WorkingDirectory=$GAME_DIR
ExecStart=$GAME_DIR/PalServer.sh -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS
Restart=always
RestartSec=10
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable palworld.service
systemctl restart palworld.service
