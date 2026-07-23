# ---------------------------------------------------------------------------
# EC2 인스턴스 역할
#   - 부팅 시 자기 자신에게 세이브 데이터 EBS 볼륨을 붙이기 위한 권한
#   - SSH 포트를 열지 않는 대신 SSM Session Manager로 접속하기 위한 권한
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "${var.project_name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ec2_self_attach" {
  statement {
    sid = "AttachOwnDataVolume"
    actions = [
      "ec2:AttachVolume",
      "ec2:DescribeVolumes",
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ec2_self_attach" {
  name   = "${var.project_name}-ec2-self-attach"
  role   = aws_iam_role.ec2_role.id
  policy = data.aws_iam_policy_document.ec2_self_attach.json
}

resource "aws_iam_instance_profile" "palworld" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.ec2_role.name
}

# ---------------------------------------------------------------------------
# Lambda 실행 역할 (스팟 중단 감지 -> 온디맨드 대체 기동)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "${var.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_failover" {
  statement {
    sid = "Ec2Failover"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeSpotInstanceRequests",
      "ec2:CancelSpotInstanceRequests",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:StopInstances",
      "ec2:StartInstances",
      "ec2:CreateTags",
      "ec2:AttachVolume",
      "ec2:DetachVolume",
      "ec2:DescribeVolumes",
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
      "ec2:DescribeAddresses",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassEc2InstanceRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ec2_role.arn]
  }

  statement {
    sid = "CheckPlayerCountViaSsm"
    actions = [
      "ssm:SendCommand",
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "ReadUserDataParameter"
    actions = ["ssm:GetParameter"]
    resources = [
      aws_ssm_parameter.user_data.arn,
      aws_ssm_parameter.standby_user_data.arn,
    ]
  }

  statement {
    sid       = "RecordPlayerCountMetric"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData는 리소스 수준 제한을 지원하지 않음
  }
}

resource "aws_iam_role_policy" "lambda_failover" {
  name   = "${var.project_name}-lambda-failover"
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.lambda_failover.json
}
