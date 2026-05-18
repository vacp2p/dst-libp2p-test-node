import argparse
import asyncio
import logging
import random
import socket
import time
from dataclasses import dataclass
from typing import Dict, Optional

import aiohttp

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(filename)s:%(lineno)d - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)


@dataclass
class Target:
    host: str
    ip: str
    url: str


async def resolve_host(host: str) -> str:
    loop = asyncio.get_running_loop()
    start = time.time()

    try:
        ip = await loop.run_in_executor(None, socket.gethostbyname, host)
        elapsed_ms = (time.time() - start) * 1000

        logging.debug(
            "DNS host=%s ip=%s elapsed_ms=%.2f",
            host,
            ip,
            elapsed_ms,
        )

        return ip

    except (socket.gaierror, socket.herror, OSError) as exc:
        raise RuntimeError(f"DNS lookup failed for host={host}: {exc}") from exc


def build_pod_hostname(args: argparse.Namespace, node_id: int) -> str:
    base = f"{args.pod_prefix}-{node_id}"

    if args.pod_domain:
        return f"{base}.{args.pod_domain}"

    return base


async def resolve_target(args: argparse.Namespace, message_index: int) -> Target:
    if args.peer_selection == "service":
        host = args.service_host

    elif args.peer_selection == "fixed":
        host = build_pod_hostname(args, args.fixed_id)

    elif args.peer_selection == "round-robin":
        node_count = args.end_id - args.start_id + 1
        node_id = args.start_id + (message_index % node_count)
        host = build_pod_hostname(args, node_id)

    elif args.peer_selection == "random-range":
        node_id = random.randint(args.start_id, args.end_id)
        host = build_pod_hostname(args, node_id)

    else:
        raise ValueError(f"Unsupported peer selection: {args.peer_selection}")

    ip = await resolve_host(host)
    url = f"http://{ip}:{args.port}/publish"

    return Target(host=host, ip=ip, url=url)


async def send_libp2p_msg(
    session: aiohttp.ClientSession,
    args: argparse.Namespace,
    stats: Dict[str, int],
    message_index: int,
):
    target = await resolve_target(args, message_index)

    headers = {"Content-Type": "application/json"}
    body = {
        "topic": args.pubsub_topic,
        "msgSize": args.msg_size_bytes,
        "version": 1,
    }

    logging.info(
        "message=%d target_host=%s target_ip=%s url=%s",
        message_index,
        target.host,
        target.ip,
        target.url,
    )

    start = time.time()

    try:
        async with session.post(
            target.url,
            json=body,
            headers=headers,
            timeout=args.request_timeout,
        ) as response:
            elapsed_ms = (time.time() - start) * 1000
            response_text = await response.text()

            stats["total"] += 1

            if response.status == 200:
                stats["success"] += 1
            else:
                stats["failure"] += 1

            success_rate = (
                (stats["success"] / stats["total"]) * 100
                if stats["total"] > 0
                else 0
            )

            logging.info(
                "message=%d target=%s status=%d elapsed_ms=%.2f success=%d failure=%d total=%d success_rate=%.2f response=%s",
                message_index,
                target.host,
                response.status,
                elapsed_ms,
                stats["success"],
                stats["failure"],
                stats["total"],
                success_rate,
                response_text[:300],
            )

    except Exception as exc:
        elapsed_ms = (time.time() - start) * 1000

        stats["total"] += 1
        stats["failure"] += 1

        success_rate = (
            (stats["success"] / stats["total"]) * 100
            if stats["total"] > 0
            else 0
        )

        logging.warning(
            "message=%d target=%s exception=%s elapsed_ms=%.2f success=%d failure=%d total=%d success_rate=%.2f",
            message_index,
            target.host,
            repr(exc),
            elapsed_ms,
            stats["success"],
            stats["failure"],
            stats["total"],
            success_rate,
        )


async def main(args: argparse.Namespace):
    stats = {
        "success": 0,
        "failure": 0,
        "total": 0,
    }

    background_tasks = set()
    start_time = time.time()
    message_index = 0

    timeout = aiohttp.ClientTimeout(total=args.request_timeout)

    async with aiohttp.ClientSession(timeout=timeout) as session:
        while True:
            if args.messages is not None and message_index >= args.messages:
                break

            if (
                args.duration_seconds is not None
                and time.time() - start_time >= args.duration_seconds
            ):
                break

            task = asyncio.create_task(
                send_libp2p_msg(session, args, stats, message_index)
            )

            background_tasks.add(task)
            task.add_done_callback(background_tasks.discard)

            message_index += 1
            await asyncio.sleep(args.delay_seconds)

        if background_tasks:
            await asyncio.gather(*background_tasks)

    elapsed_s = time.time() - start_time
    success_rate = (
        (stats["success"] / stats["total"]) * 100
        if stats["total"] > 0
        else 0
    )

    logging.info(
        "finished elapsed_s=%.2f success=%d failure=%d total=%d success_rate=%.2f",
        elapsed_s,
        stats["success"],
        stats["failure"],
        stats["total"],
        success_rate,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="nim-libp2p message injector")

    parser.add_argument(
        "-t",
        "--pubsub-topic",
        type=str,
        default="test",
        help="PubSub topic",
    )

    parser.add_argument(
        "-s",
        "--msg-size-bytes",
        type=int,
        default=1000,
        help="Message size in bytes",
    )

    parser.add_argument(
        "-d",
        "--delay-seconds",
        type=float,
        default=1.0,
        help="Delay between publish requests",
    )

    parser.add_argument(
        "-m",
        "--messages",
        type=int,
        default=None,
        help="Number of messages to inject",
    )

    parser.add_argument(
        "--duration-seconds",
        type=float,
        default=None,
        help="Duration of the injection phase. Use either this or --messages.",
    )

    parser.add_argument(
        "--peer-selection",
        type=str,
        choices=["service", "fixed", "round-robin", "random-range"],
        default="service",
        help="How to select the test node receiving /publish requests",
    )

    parser.add_argument(
        "--service-host",
        type=str,
        default="nimp2p-service",
        help="Kubernetes service hostname for service-based peer selection",
    )

    parser.add_argument(
        "--pod-prefix",
        type=str,
        default="nim-quic-normal",
        help="StatefulSet pod prefix for fixed/range selection",
    )

    parser.add_argument(
        "--pod-domain",
        type=str,
        default="nimp2p-service",
        help="Headless service DNS domain. Example: nimp2p-service",
    )

    parser.add_argument(
        "--fixed-id",
        type=int,
        default=0,
        help="Pod ordinal used with --peer-selection fixed",
    )

    parser.add_argument(
        "--start-id",
        type=int,
        default=0,
        help="Start ordinal for round-robin/random-range selection",
    )

    parser.add_argument(
        "--end-id",
        type=int,
        default=99,
        help="End ordinal for round-robin/random-range selection",
    )

    parser.add_argument(
        "-p",
        "--port",
        type=int,
        default=8645,
        help="test node HTTP publish port",
    )

    parser.add_argument(
        "--request-timeout",
        type=float,
        default=10.0,
        help="HTTP request timeout in seconds",
    )

    args = parser.parse_args()

    if args.messages is None and args.duration_seconds is None:
        parser.error("Set either --messages or --duration-seconds")

    if args.messages is not None and args.duration_seconds is not None:
        parser.error("Use either --messages or --duration-seconds, not both")

    if args.start_id > args.end_id:
        parser.error("--start-id must be <= --end-id")

    return args


if __name__ == "__main__":
    parsed_args = parse_args()
    logging.info("args=%s", parsed_args)
    asyncio.run(main(parsed_args))