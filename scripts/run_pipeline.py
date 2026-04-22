import time
import requests
import subprocess
import os
import sys

# Add the project root to sys.path to import infrastructure.manage_vllm_gpu
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from infrastructure.manage_vllm_gpu import launch_instance, ec2

def wait_for_vllm(ip, timeout_minutes=10):
    """
    Polls the vLLM embedding endpoint until it's ready.
    It takes a few minutes to pull the docker image and load the model.
    """
    url = f"http://{ip}:8000/v1/embeddings"
    print(f"\n⏳ Waiting for vLLM to start at {url}...")
    print(f"   (This usually takes 3-7 minutes for first-time Docker pull)")
    
    start_time = time.time()
    while time.time() - start_time < (timeout_minutes * 60):
        try:
            # Simple test payload
            res = requests.post(
                url, 
                json={"model": "BAAI/bge-small-en-v1.5", "input": ["health check"]}, 
                timeout=5
            )
            if res.status_code == 200:
                print("\n✅ vLLM is ONLINE and ready!")
                return True
        except requests.exceptions.RequestException:
            pass
        
        time.sleep(15)
        elapsed = int(time.time() - start_time)
        print(f"   ... still waiting ({elapsed}s elapsed)", end="\r")
    
    print("\n❌ Timeout: vLLM did not start within the expected time.")
    return False

def run_spark_job(vllm_ip):
    """
    Triggers the Spark ingestion job with the vLLM endpoint set in environment.
    """
    print(f"\n🚀 Starting Spark Embedding Job...")
    print(f"   Connecting to vLLM at: {vllm_ip}")
    
    env = os.environ.copy()
    env["VLLM_ENDPOINT"] = f"http://{vllm_ip}:8000/v1/embeddings"
    
    cmd = [
        "spark-submit",
        "--master", "local[*]",
        "spark_jobs/ingest_to_lancedb.py"
    ]
    
    try:
        subprocess.run(cmd, env=env, check=True)
        print("\n✅ Pipeline completed successfully!")
    except subprocess.CalledProcessError as e:
        print(f"\n❌ Spark Job failed with error: {e}")

def main():
    print("--- RAG PORTFOLIO PIPELINE ORCHESTRATOR ---")
    
    # 1. Launch/Find GPU Instance
    # Tries Spot first, then On-Demand
    instance_id = launch_instance(use_spot=True)
    if not instance_id:
        instance_id = launch_instance(use_spot=False)
        
    if not instance_id:
        print("❌ CRITICAL ERROR: Could not provision a GPU instance.")
        return

    # 2. Get Private IP (assuming Spark runs in the same VPC)
    print("Fetching instance network details...")
    waiter = ec2.get_waiter('instance_running')
    waiter.wait(InstanceIds=[instance_id])
    
    instance_info = ec2.describe_instances(InstanceIds=[instance_id])['Reservations'][0]['Instances'][0]
    vllm_ip = instance_info.get('PrivateIpAddress')
    
    if not vllm_ip:
        print("❌ Error: Could not retrieve IP address. check AWS console.")
        return

    # 3. Wait for Docker + vLLM to be ready
    if wait_for_vllm(vllm_ip):
        # 4. Execute Spark Ingestion
        run_spark_job(vllm_ip)
    else:
        print(f"Please check the GPU instance {instance_id} logs for errors.")

if __name__ == "__main__":
    main()
