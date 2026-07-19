"""
두 종류의 EventBridge 이벤트를 하나의 Lambda가 처리한다.

1) EC2 Spot Instance Interruption Warning (중단 2분 전 예고)
   - 접속자가 0명이면: 아무것도 하지 않는다.
     (persistent + stop 스팟 요청이라 AWS가 알아서 정지시키고,
      나중에 스팟 용량이 다시 확보되면 자동으로 재기동해준다)
   - 접속자가 있으면: 온디맨드 인스턴스로 즉시 대체 기동하고
     세이브 데이터 EBS 볼륨 + Elastic IP를 새 인스턴스로 옮긴다.

2) 주기적인 스팟 복귀 체크 (기본 30분 간격, task=reclaim_check)
   - 지금 떠있는 인스턴스가 이미 스팟이면 아무것도 안 한다.
   - 온디맨드로 떠있다면(과거에 1번 케이스로 넘어간 상태) 접속자 수를 확인해서
     0명일 때만 스팟 인스턴스를 새로 띄우는 걸 시도하고, EBS/EIP를 옮긴 뒤
     온디맨드 인스턴스를 종료한다. 스팟 용량이 아직 없으면 그냥 넘어가고
     다음 주기에 다시 시도한다.

3) 주기적인 지표 기록 (기본 5분 간격, task=record_metrics)
   - 접속자 수를 확인해서 CloudWatch 커스텀 지표(<project>/GameServer
     PlayerCount)로 기록한다. CloudWatch 대시보드에서 CPU/네트워크와
     같이 시계열로 볼 수 있다.

2), 3)번은 둘 다 EventBridge 스케줄 규칙이 트리거하는데, EventBridge의
기본 Scheduled Event 포맷 대신 `input`으로 `{"task": "..."}` 를 넘겨서
어떤 스케줄인지 구분한다 (terraform/eventbridge.tf 참고).

접속자 수 확인이 실패한 경우(REST API 무응답 등)에는 "접속자가 있다"고
안전하게 간주한다 - 불필요한 전환 비용보다 접속 끊김/세이브 유실이 훨씬 더
나쁜 결과이기 때문이다. (스팟 -> 온디맨드 방향, 온디맨드 -> 스팟 방향 모두 동일)
"""
import json
import os
import time

import boto3
from botocore.exceptions import ClientError

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")
cloudwatch = boto3.client("cloudwatch")

PROJECT_NAME = os.environ["PROJECT_NAME"]
DATA_VOLUME_ID = os.environ["DATA_VOLUME_ID"]
DATA_VOLUME_DEVICE = os.environ["DATA_VOLUME_DEVICE"]
EIP_ALLOCATION_ID = os.environ["EIP_ALLOCATION_ID"]
SECURITY_GROUP_ID = os.environ["SECURITY_GROUP_ID"]
SUBNET_ID = os.environ["SUBNET_ID"]
AMI_ID = os.environ["AMI_ID"]
INSTANCE_PROFILE_NAME = os.environ["INSTANCE_PROFILE_NAME"]
INSTANCE_TYPE = os.environ["INSTANCE_TYPE"]
USER_DATA_PARAMETER_NAME = os.environ["USER_DATA_PARAMETER_NAME"]

SSM_COMMAND_TIMEOUT_SECONDS = 45
SSM_POLL_INTERVAL_SECONDS = 3

SPOT_MARKET_OPTIONS = {
    "MarketType": "spot",
    "SpotOptions": {
        "SpotInstanceType": "persistent",
        "InstanceInterruptionBehavior": "stop",
    },
}

PLAYER_COUNT_SCRIPT = (
    "ADMIN_PW=$(grep -oP 'AdminPassword=\"\\K[^\"]+' "
    "/mnt/palworld-data/Palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini) && "
    "curl -sf -u admin:$ADMIN_PW http://127.0.0.1:8212/v1/api/players "
    "| python3 -c 'import json,sys; print(len(json.load(sys.stdin)[\"players\"]))'"
)


def handler(event, context):
    if event.get("detail-type") == "EC2 Spot Instance Interruption Warning":
        _handle_interruption_warning(event)
    elif event.get("task") == "reclaim_check":
        _handle_scheduled_reclaim_check()
    elif event.get("task") == "record_metrics":
        _handle_record_metrics()
    else:
        print(f"Unrecognized event, ignoring: {json.dumps(event)}")


# ---------------------------------------------------------------------------
# 1) 스팟 중단 예고 -> 필요시 온디맨드로 즉시 대체 기동
# ---------------------------------------------------------------------------
def _handle_interruption_warning(event):
    detail = event.get("detail", {})
    instance_id = detail.get("instance-id")
    if not instance_id:
        print(f"No instance-id in event, ignoring: {json.dumps(event)}")
        return

    if not _has_project_tag(instance_id):
        print(f"{instance_id} is not tagged Project={PROJECT_NAME}, ignoring")
        return

    player_count = _get_player_count(instance_id)
    print(f"player_count={player_count} on {instance_id}")

    if player_count == 0:
        print(
            "No players connected - leaving the instance to stop. "
            "AWS will auto-restart this persistent spot request once capacity is available again."
        )
        return

    print(f"players={player_count} (or unknown) - failing over to an on-demand instance")
    _cancel_spot_request(instance_id)
    new_instance_id = _launch_instance("ondemand-failover")
    _swap_instance(old_instance_id=instance_id, new_instance_id=new_instance_id)
    print(f"Failover complete: {instance_id} -> {new_instance_id}")


def _cancel_spot_request(instance_id):
    resp = ec2.describe_instances(InstanceIds=[instance_id])
    instance = resp["Reservations"][0]["Instances"][0]
    spot_request_id = instance.get("SpotInstanceRequestId")
    if spot_request_id:
        print(f"Cancelling spot request {spot_request_id} so it doesn't refulfill later")
        ec2.cancel_spot_instance_requests(SpotInstanceRequestIds=[spot_request_id])


# ---------------------------------------------------------------------------
# 2) 주기적으로 온디맨드 -> 스팟 복귀가 가능한지 확인
# ---------------------------------------------------------------------------
def _handle_scheduled_reclaim_check():
    instance = _find_running_instance()
    if instance is None:
        print("No running Project-tagged instance found, nothing to do")
        return

    instance_id = instance["InstanceId"]
    if instance.get("InstanceLifecycle") == "spot":
        print(f"{instance_id} is already a spot instance, nothing to do")
        return

    print(f"{instance_id} is on-demand - checking whether it's safe to move back to spot")
    player_count = _get_player_count(instance_id)
    if player_count != 0:
        print(f"players={player_count} (or unknown) - not switching back to spot while someone might be playing")
        return

    print("No players connected - attempting to reclaim a spot instance")
    try:
        new_instance_id = _launch_instance("spot", market_options=SPOT_MARKET_OPTIONS)
    except ClientError as exc:
        print(f"Could not launch a spot instance right now (capacity probably unavailable): {exc}")
        return

    _swap_instance(old_instance_id=instance_id, new_instance_id=new_instance_id)
    print(f"Reclaimed spot instance: {instance_id} -> {new_instance_id}")


# ---------------------------------------------------------------------------
# 3) 접속자 수를 CloudWatch 커스텀 지표로 기록
# ---------------------------------------------------------------------------
def _handle_record_metrics():
    instance = _find_running_instance()
    if instance is None:
        print("No running Project-tagged instance found, skipping metric")
        return

    player_count = _get_player_count(instance["InstanceId"])
    if player_count is None:
        print("Could not determine player count this cycle, skipping metric")
        return

    cloudwatch.put_metric_data(
        Namespace=f"{PROJECT_NAME}/GameServer",
        MetricData=[
            {
                "MetricName": "PlayerCount",
                "Value": player_count,
                "Unit": "Count",
            }
        ],
    )
    print(f"Recorded PlayerCount={player_count}")


def _find_running_instance():
    resp = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Project", "Values": [PROJECT_NAME]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    )
    instances = [i for r in resp["Reservations"] for i in r["Instances"]]
    return instances[0] if instances else None


# ---------------------------------------------------------------------------
# 공통 헬퍼
# ---------------------------------------------------------------------------
def _has_project_tag(instance_id):
    resp = ec2.describe_instances(InstanceIds=[instance_id])
    tags = resp["Reservations"][0]["Instances"][0].get("Tags", [])
    return any(t["Key"] == "Project" and t["Value"] == PROJECT_NAME for t in tags)


def _get_player_count(instance_id):
    try:
        send_resp = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": [PLAYER_COUNT_SCRIPT]},
            TimeoutSeconds=SSM_COMMAND_TIMEOUT_SECONDS,
        )
        command_id = send_resp["Command"]["CommandId"]
    except Exception as exc:  # noqa: BLE001 - SSM/agent not ready, etc.
        print(f"SSM send_command failed: {exc}")
        return None

    deadline = time.time() + SSM_COMMAND_TIMEOUT_SECONDS
    while time.time() < deadline:
        time.sleep(SSM_POLL_INTERVAL_SECONDS)
        try:
            inv = ssm.get_command_invocation(CommandId=command_id, InstanceId=instance_id)
        except ssm.exceptions.InvocationDoesNotExist:
            continue

        status = inv["Status"]
        if status == "Success":
            try:
                return int(inv["StandardOutputContent"].strip())
            except ValueError:
                print(f"Unexpected SSM output: {inv['StandardOutputContent']!r}")
                return None
        if status in ("Failed", "Cancelled", "TimedOut"):
            print(f"SSM command ended with status={status}: {inv.get('StandardErrorContent')}")
            return None

    print("Timed out waiting for SSM command result")
    return None


def _launch_instance(name_suffix, market_options=None):
    user_data = ssm.get_parameter(Name=USER_DATA_PARAMETER_NAME)["Parameter"]["Value"]

    kwargs = dict(
        ImageId=AMI_ID,
        InstanceType=INSTANCE_TYPE,
        MinCount=1,
        MaxCount=1,
        SubnetId=SUBNET_ID,
        SecurityGroupIds=[SECURITY_GROUP_ID],
        IamInstanceProfile={"Name": INSTANCE_PROFILE_NAME},
        UserData=user_data,
        TagSpecifications=[
            {
                "ResourceType": "instance",
                "Tags": [
                    {"Key": "Project", "Value": PROJECT_NAME},
                    {"Key": "Name", "Value": f"{PROJECT_NAME}-server-{name_suffix}"},
                ],
            }
        ],
    )
    if market_options:
        kwargs["InstanceMarketOptions"] = market_options

    resp = ec2.run_instances(**kwargs)
    instance_id = resp["Instances"][0]["InstanceId"]
    print(f"Launched instance {instance_id} (name_suffix={name_suffix})")
    return instance_id


def _swap_instance(old_instance_id, new_instance_id):
    """old_instance_id에서 new_instance_id로 세이브 볼륨 + Elastic IP를 옮기고
    old_instance_id를 종료한다. 두 방향(스팟<->온디맨드) 모두 동일하게 쓰인다."""
    _wait_until_running(new_instance_id)
    _move_data_volume(old_instance_id, new_instance_id)
    _move_elastic_ip(new_instance_id)

    print(f"Terminating old instance {old_instance_id}")
    ec2.terminate_instances(InstanceIds=[old_instance_id])


def _wait_until_running(instance_id):
    waiter = ec2.get_waiter("instance_running")
    waiter.wait(InstanceIds=[instance_id], WaiterConfig={"Delay": 5, "MaxAttempts": 12})


def _move_data_volume(old_instance_id, new_instance_id):
    print(f"Detaching data volume {DATA_VOLUME_ID} from {old_instance_id}")
    try:
        ec2.detach_volume(VolumeId=DATA_VOLUME_ID, InstanceId=old_instance_id, Force=True)
    except Exception as exc:  # noqa: BLE001 - already detached/instance gone, etc.
        print(f"detach_volume warning (continuing): {exc}")

    waiter = ec2.get_waiter("volume_available")
    waiter.wait(VolumeIds=[DATA_VOLUME_ID], WaiterConfig={"Delay": 3, "MaxAttempts": 20})

    print(f"Attaching data volume {DATA_VOLUME_ID} to {new_instance_id}")
    ec2.attach_volume(VolumeId=DATA_VOLUME_ID, InstanceId=new_instance_id, Device=DATA_VOLUME_DEVICE)


def _move_elastic_ip(new_instance_id):
    print(f"Associating EIP {EIP_ALLOCATION_ID} with {new_instance_id}")
    ec2.associate_address(
        AllocationId=EIP_ALLOCATION_ID,
        InstanceId=new_instance_id,
        AllowReassociation=True,
    )
