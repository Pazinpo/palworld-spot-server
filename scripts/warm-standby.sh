#!/bin/bash
# 예비(warm standby) 인스턴스용 준비 스크립트.
#
# install-palworld.sh와 달리 세이브 데이터 볼륨을 건드리지 않고, 딱
# "패키지 설치 + SteamCMD 부트스트랩"까지만 미리 해둔다. 이 인스턴스는
# 평소엔 정지(stopped) 상태로 대기하다가, 스팟 중단으로 온디맨드 전환이
# 필요해지면 Lambda가 그냥 "시작"만 시켜서 쓴다 - apt/SteamCMD 설치 시간을
# 통째로 아끼는 게 목적이다. (실제 게임 마운트/서비스 등록은 Lambda가
# 세이브 볼륨을 붙인 뒤 별도로 수행한다)
set -euxo pipefail
exec > >(tee -a /var/log/palworld-standby-prep.log) 2>&1

wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    sleep 2
  done
}

wait_for_apt
apt-get update -y
apt-get install -y curl unzip jq fuse

if ! command -v aws >/dev/null 2>&1; then
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
fi

dpkg --add-architecture i386
wait_for_apt
apt-get update -y
apt-get install -y software-properties-common
add-apt-repository -y multiverse || true
wait_for_apt
apt-get update -y
apt-get install -y lib32gcc-s1 lib32stdc++6 ca-certificates locales

if ! id -u steam >/dev/null 2>&1; then
  useradd -m -s /bin/bash steam
fi

mkdir -p /home/steam/steamcmd
chown steam:steam /home/steam/steamcmd

if [ ! -f /home/steam/steamcmd/steamcmd.sh ]; then
  su - steam -c "curl -sqL 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz' | tar zxvf - -C /home/steam/steamcmd"
fi

# steamcmd 자체를 한 번 부트스트랩(자기 자신 업데이트)해두면, 나중에
# 실제로 앱을 설치할 때 "Missing configuration" 같은 첫 실행 에러가
# 훨씬 덜 난다. 앱은 설치하지 않는다(어차피 세이브 볼륨에 이미 있음).
for attempt in 1 2 3; do
  if su - steam -c "/home/steam/steamcmd/steamcmd.sh +quit"; then
    break
  fi
  echo "steamcmd bootstrap attempt $attempt failed, retrying..." >&2
  sleep 5
done

touch /tmp/standby-ready
echo "standby prep complete"
