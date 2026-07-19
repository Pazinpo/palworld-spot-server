# 세이브 데이터 EBS 볼륨의 자동 스냅샷 백업.
#
# EBS 볼륨 자체는 인스턴스 교체(스팟<->온디맨드)에도 살아남지만, 볼륨
# 자체가 손상되거나 실수로 삭제되는 경우엔 별도 대비가 없었다. Data
# Lifecycle Manager로 매일 스냅샷을 찍어서 최근 며칠치를 따로 보관한다.
# DLM 서비스 자체는 무료고, 스냅샷 저장 용량만큼만 과금된다(서울 리전
# 기준 GB당 월 $0.05, 실사용량 기준 증분 저장이라 세이브 데이터처럼
# 작은 볼륨은 월 몇백 원 수준).
data "aws_iam_policy_document" "dlm_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${var.project_name}-dlm-role"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume_role.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "palworld_data_backup" {
  description        = "${var.project_name} save-data volume daily snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Name = "${var.project_name}-data"
    }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["17:00"] # UTC 17:00 = KST 02:00, 다들 안 할 시간대
      }

      retain_rule {
        count = var.snapshot_retention_count
      }

      tags_to_add = {
        Project = var.project_name
      }

      copy_tags = true
    }
  }
}
