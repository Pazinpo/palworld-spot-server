"""
EC2 Spot Instance Interruption Warning(중단 2분 전 예고)을 받아서
  - 접속자가 0명이면: 아무것도 하지 않는다.
    (인스턴스는 persistent + stop 스팟 요청이라 AWS가 알아서 정지시키고,
     나중에 스팟 용량이 다시 확보되면 자동으로 재기동해준다)
  - 접속자가 있으면: 온디맨드 인스턴스로 즉시 대체 기동하고
    세이브 데이터 EBS 볼륨 + Elastic IP를 새 인스턴스로 옮긴다.

접속자 수 확인이 실패한 경우(REST API 무응답 등)에는 "접속자가 있다"고
안전하게 간주한다 - 불필요한 온디맨드 전환 비용보다 접속 끊김/세이브 유실이
훨씬 더 나쁜 결과이기 때문이다.
"""
import json
import os
import time

import boto3

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")

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

PLAYER_COUNT_SCRIPT = (
    "ADMIN_PW=$(grep -oP 'AdminPassword=\"\\K[^\"]+' "
    "/mnt/palworld-data/Palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini) && "
    "curl -sf -u admin:$ADMIN_PW http://127.0.0.1:8212/v1/api/players "
    "| python3 -c 'import json,sys; print(len(json.load(sys.stdin)[\"players\"]))'"
)


def handler(event, context):
    detail = event.get("detail", {})
    instance_id = detail.get("instance-id")
    if not instance_id:
        print(f"No instance-id in event, ignoring: {json.dumps(event)}")
        return

    if not _is_our_instance(instance_id):
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
    _failover_to_on_demand(instance_id)


def _is_our_instance(instance_id):
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


def _failover_to_on_demand(old_instance_id):
    _cancel_spot_request(old_instance_id)

    new_instance_id = _launch_on_demand_instance()
    _wait_until_running(new_instance_id)

    _move_data_volume(old_instance_id, new_instance_id)
    _move_elastic_ip(new_instance_id)

    print(f"Terminating old spot instance {old_instance_id}")
    ec2.terminate_instances(InstanceIds=[old_instance_id])

    print(f"Failover complete: {old_instance_id} -> {new_instance_id}")


def _cancel_spot_request(instance_id):
    resp = ec2.describe_instances(InstanceIds=[instance_id])
    instance = resp["Reservations"][0]["Instances"][0]
    spot_request_id = instance.get("SpotInstanceRequestId")
    if spot_request_id:
        print(f"Cancelling spot request {spot_request_id} so it doesn't refulfill later")
        ec2.cancel_spot_instance_requests(SpotInstanceRequestIds=[spot_request_id])


def _launch_on_demand_instance():
    user_data = ssm.get_parameter(Name=USER_DATA_PARAMETER_NAME)["Parameter"]["Value"]

    resp = ec2.run_instances(
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
                    {"Key": "Name", "Value": f"{PROJECT_NAME}-server-ondemand-failover"},
                ],
            }
        ],
    )
    instance_id = resp["Instances"][0]["InstanceId"]
    print(f"Launched on-demand instance {instance_id}")
    return instance_id


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
