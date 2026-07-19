data "aws_caller_identity" "current" {}

# 별도 VPC를 새로 만들지 않고 계정 기본 VPC/서브넷을 사용한다 (친구용 소규모 서버라 네트워크 비용/복잡도를 줄임).
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "selected" {
  id = sort(data.aws_subnets.default.ids)[0]
}

# Palworld 전용 서버는 SteamCMD(32비트 바이너리)가 필요해 멀티립을 공식 지원하는 Ubuntu 22.04 LTS를 사용한다.
# (Amazon Linux 2023은 32비트 멀티립 저장소를 제공하지 않아 SteamCMD 설치가 번거롭다.)
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}
