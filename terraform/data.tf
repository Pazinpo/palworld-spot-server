data "aws_caller_identity" "current" {}

# 별도 VPC를 새로 만들지 않고 계정 기본 VPC/서브넷을 사용한다 (친구용 소규모 서버라 네트워크 비용/복잡도를 줄임).
data "aws_vpc" "default" {
  default = true
}

# 스팟 가격은 AZ마다 꽤 차이가 나는 반면(같은 서울 리전 안이라 지연시간 차이는
# 사실상 없음), 비용 예측이 가능하도록 var.availability_zone으로 고정한다.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = [var.availability_zone]
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
