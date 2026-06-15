import os
from prefect import flow, task, get_run_logger


@task
def fetch_data(name: str) -> dict:
    logger = get_run_logger()
    logger.info(f"Fetching data for: {name}")
    return {"name": name, "value": 42}


@task
def process_data(data: dict) -> str:
    logger = get_run_logger()
    result = f"Processed {data['name']} → value={data['value'] * 2}"
    logger.info(result)
    return result


@task
def save_result(result: str) -> None:
    get_run_logger().info(f"Saving result: {result}")


@flow(name="hello-flow", log_prints=True)
def hello_flow(name: str = "world"):
    data = fetch_data(name)
    result = process_data(data)
    save_result(result)
    print(f"Flow complete: {result}")


if __name__ == "__main__":
    hello_flow(name=os.getenv("FLOW_NAME", "prefect"))
