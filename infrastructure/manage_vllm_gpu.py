import boto3
import time
import sys

# Configuration
REGION = "us-east-1"
INSTANCE_TYPE = "g4dn.xlarge"
IMAGE_ID = "ami-00581b89b09f56ac6" # Deep Learning OSS Nvidia Driver AMI GPU PyTorch 2.5.1 (Ubuntu 22.04)
KEY_NAME = "poc-key"
SECURITY_GROUP_IDS = ["sg-0123456789abcdef0"] # Update with your SG
SUBNET_ID = "subnet-xxxxxxxx"              # Update with your Subnet

ec2 = boto3.client('ec2', region_name=REGION)

USER_DATA = """#!/lnbin/bash
# Install Docker if not present
yum update -y
amazon-linux-extras install docker -y
service docker start
usermod -a -G docker ec2-user

# Run vLLM with the embedding model
docker run -d --gpus all -p 8000:8000 \
    -e HF_TOKEN=${HF_TOKEN} \
    vllm/vllm-openai \
    --model BAAI/bge-small-en-v1.5 \
    --task embedding
"""

def launch_instance(use_spot=True):
    market_options = {}
    if use_spot:
        print(f"Attempting to launch {INSTANCE_TYPE} as SPOT...")
        market_options = {
            'MarketType': 'spot',
            'SpotOptions': {
                'SpotInstanceType': 'one-time',
                'InstanceInterruptionBehavior': 'terminate'
            }
        }
    else:
        print(f"Falling back to ON-DEMAND for {INSTANCE_TYPE}...")

    try:
        response = ec2.run_instances(
            ImageId=IMAGE_ID,
            InstanceType=INSTANCE_TYPE,
            MinCount=1,
            MaxCount=1,
            KeyName=KEY_NAME,
            InstanceMarketOptions=market_options,
            UserData=USER_DATA,
            TagSpecifications=[{
                'ResourceType': 'instance',
                'Tags': [{'Key': 'Name', 'Value': 'vLLM-Embedding-Server'}]
            }]
        )
        instance_id = response['Instances'][0]['InstanceId']
        print(f"Success! Instance ID: {instance_id}")
        return instance_id
    except Exception as e:
        print(f"Failed to launch: {str(e)}")
        return None

def main():
    # Try Spot first
    instance_id = launch_instance(use_spot=True)
    
    # If Spot fails (e.g. InsufficientInstanceCapacity), fallback to On-Demand
    if not instance_id:
        instance_id = launch_instance(use_spot=False)
    
    if not instance_id:
        print("Error: Could not launch instance in either Spot or On-Demand mode.")
        sys.exit(1)

    print("Waiting for instance to be 'running'...")
    waiter = ec2.get_waiter('instance_running')
    waiter.wait(InstanceIds=[instance_id])
    
    instance = ec2.describe_instances(InstanceIds=[instance_id])['Reservations'][0]['Instances'][0]
    private_ip = instance.get('PrivateIpAddress')
    
    print(f"\n--- GPU SERVER READY ---")
    print(f"Instance ID: {instance_id}")
    print(f"Private IP:  {private_ip}")
    print(f"vLLM Endpoint: http://{private_ip}:8000/v1/embeddings")
    print(f"Note: It may take 3-5 minutes for the Docker container to pull and start.")

if __name__ == "__main__":
    main()
