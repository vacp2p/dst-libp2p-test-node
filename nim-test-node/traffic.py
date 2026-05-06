import argparse
import asyncio
import logging
import socket
import time
from typing import Dict, Tuple

import aiohttp

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(filename)s:%(lineno)d - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)


async def check_dns_time(service: str) -> tuple[str, str]:
    start_time = time.time()
    try:
        ip_address = socket.gethostbyname(service)
        elapsed = (time.time() - start_time) * 1000
        try:
            entire_hostname = socket.gethostbyaddr(ip_address)
            hostname = entire_hostname[0].split(".")[0]
        except (socket.herror, OSError):
            # Docker Compose may not have reverse DNS, use IP as hostname
            hostname = ip_address
        logging.info(f"{service} DNS Response took {elapsed} ms. Resolved to {hostname}.")
        return f"{ip_address}", hostname
    except (socket.gaierror, socket.herror) as e:
        logging.error(f"Failed DNS lookup for service: `{service}`: `{e}`")
        raise RuntimeError("Failed check_dns_time") from e


async def get_publisher_details(
    args: argparse.Namespace, publisher: int, action: str
) -> Tuple[str, Dict[str, str], Dict[str, str | int], str]:
    if args.peer_selection == "service":  # make random publisher selection
        node_address, node_hostname = await check_dns_time(args.service_host)
    else:
        node_index = publisher % args.network_size
        node_hostname = f"pod-{node_index}"
        node_address = socket.gethostbyname(node_hostname)

    url = f"http://{node_address}:{args.port}/{action}"
    headers = {"Content-Type": "application/json"}
    body = {"topic": args.pubsub_topic, "msgSize": args.msg_size_bytes, "version": 1}

    return url, headers, body, node_hostname


async def send_libp2p_msg(args: argparse.Namespace, stats: Dict[str, int], i: int):
    # Create request message
    url, headers, body, node_hostname = await get_publisher_details(args, i, "publish")
    logging.info(
        f"Message {i} sending at {time.strftime('%H:%M:%S')} to publisher {node_hostname} url: {url}"
    )
    start_time = time.time()
    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(url, json=body, headers=headers) as response:
                elapsed_time = (time.time() - start_time) * 1000
                response_text = await response.text()
                log_line = f"Response from message {i + 1} sent to {node_hostname} status:{response.status}, {response_text},\n"

                if response.status == 200:
                    stats["success"] += 1
                else:
                    stats["failure"] += 1
                    log_line += f"Url: {url}, headers: {headers}, body: {body},\n"
                stats["total"] += 1

                success_rate = (
                    (stats["success"] / stats["total"]) * 100 if stats["total"] > 0 else 0
                )
                logging.info(
                    f"{log_line}"
                    f"Time: [{elapsed_time:.4f} ms], "
                    f"Success: {stats['success']}, Failure: {stats['failure']}, "
                    f"Success Rate: {success_rate:.2f}%"
                )
    except Exception as e:
        elapsed_time = (time.time() - start_time) * 1000
        stats["failure"] += 1
        stats["total"] += 1
        success_rate = (stats["success"] / stats["total"]) * 100 if stats["total"] > 0 else 0
        logging.info(
            f"Exception during message {i} sent to {node_hostname} : {str(e)}, Time: [{elapsed_time:.4f} ms], "
            f"Url: {url}, headers: {headers}, body: {body}"
            f"Success: {stats['success']}, Failure: {stats['failure']}, "
            f"Success Rate: {success_rate:.2f}%"
        )


async def main(args: argparse.Namespace):
    background_tasks = set()
    stats = {"success": 0, "failure": 0, "total": 0}

    for i in range(args.messages):
        task = asyncio.create_task(send_libp2p_msg(args, stats, i))
        background_tasks.add(task)
        task.add_done_callback(background_tasks.discard)
        await asyncio.sleep(args.delay_seconds)

    await asyncio.gather(*background_tasks)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="nim-libp2p message injector")
    parser.add_argument("-t", "--pubsub-topic", type=str, help="Pubsub topic", default="test")
    parser.add_argument(
        "-s", "--msg-size-bytes", type=int, help="Message size in Bytes", default=1000
    )
    parser.add_argument(
        "-d", "--delay-seconds", type=float, help="Delay between messages", default=1
    )
    parser.add_argument(
        "-m", "--messages", type=int, help="Number of messages to inject", default=10
    )
    parser.add_argument(
        "--peer-selection",
        type=str,
        choices=["service", "id"],
        help="Use DNS service or id-based peer selection",
        default="id",
    )
    parser.add_argument(
        "--service-host",
        type=str,
        help="Service hostname for DNS discovery (default: nimp2p-service)",
        default="nimp2p-service",
    )
    parser.add_argument("-p", "--port", type=int, help="libp2p testnode REST port", default=8645)
    parser.add_argument(
        "-n", "--network-size", type=int, help="Number of peers in the network", default=100
    )

    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    logging.info(f"{args}")
    asyncio.run(main(args))
