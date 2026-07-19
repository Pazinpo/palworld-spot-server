# 세이브 데이터 전용 EBS 볼륨. 루트 볼륨과 분리해서 인스턴스가
# 스팟->온디맨드로 교체되더라도 이 볼륨만 재부착하면 세이브가 유지된다.
resource "aws_ebs_volume" "palworld_data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.data_volume_size
  type              = "gp3"

  tags = {
    Name = "${var.project_name}-data"
  }

  lifecycle {
    prevent_destroy = true
  }
}
