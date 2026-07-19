# 인스턴스가 스팟<->온디맨드로 교체되어도 친구들이 같은 IP로 재접속할 수 있도록
# Elastic IP를 고정으로 사용한다. 실제 연결(associate)은 초기 인스턴스에 대해서만
# Terraform이 관리하고, 장애조치(failover) 시점의 재연결은 Lambda가 담당한다.
resource "aws_eip" "palworld" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-eip"
  }
}
