import argparse
import asyncio
import logging
import random
import socket
import time
from dataclasses import dataclass
from typing import Dict, List, Optional

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


class Stats:
    def __init__(self) -> None:
        self.success = 0
        self.failure = 0
        self.total = 0
        self.lock = asyncio.Lock()

    async def record(self, ok: bool) -> None:
        async with self.lock:
            self.total += 1
            if ok:
                self.success += 1
            else:
                self.failure += 1

    async def snapshot(self) -> Dict[str, float]:
        async with self.lock:
            success_rate = (self.success / self.total * 100.0) if self.total else 0.0
            return {
                "success": self.success,
                "failure": self.failure,
                "total": self.total,
                "success_rate": success_rate,
            }


async def resolve_host(host: str) -> str:
    loop = asyncio.get_running_loop()
    start = time.time()

    try:
        ip = await loop.run_in_executor(None, socket.gethostbyname, host)
        elapsed_ms = (time.time() - start) * 1000.0

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


def parse_target_ids(value: str) -> List[int]:
    """
    Parse target IDs.

    Supported formats:
      0
      0,1,2
      0-9
      0-9,20,25-30
    """
    result: List[int] = []

    for part in value.split(","):
        part = part.strip()

        if not part:
            continue

        if "-" in part:
            start_s, end_s = part.split("-", 1)
            start = int(start_s)
            end = int(end_s)

            if end < start:
                raise ValueError(f"Invalid target ID range: {part}")

            result.extend(range(start, end + 1))
        else:
            result.append(int(part))

    return sorted(set(result))


def parse_target_hosts(value: str) -> List[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


async def make_target(host: str, port: int) -> Target:
    ip = await resolve_host(host)
    url = f"http://{ip}:{port}/publish"
    return Target(host=host, ip=ip, url=url)


async def resolve_target_global(args: argparse.Namespace, message_index: int) -> Target:
    if args.peer_selection == "service":
        host = args.service_host

    elif args.peer_selection == "fixed":
        host = build_pod_hostname(args, args.fixed_id)

    elif args.peer_selection == "round-robin":
        node_count = args.end_id - args.start_id + 1

        if node_count <= 0:
            raise ValueError("--end-id must be >= --start-id for round-robin mode")

        node_id = args.start_id + (message_index % node_count)
        host = build_pod_hostname(args, node_id)

    elif args.peer_selection == "random-range":
        if args.end_id < args.start_id:
            raise ValueError("--end-id must be >= --start-id for random-range mode")

        node_id = random.randint(args.start_id, args.end_id)
        host = build_pod_hostname(args, node_id)

    else:
        raise ValueError(f"Unsupported peer selection: {args.peer_selection}")

    return await make_target(host, args.port)


async def get_per_node_targets(args: argparse.Namespace) -> List[Target]:
    if args.target_hosts:
        hosts = parse_target_hosts(args.target_hosts)

    elif args.target_ids:
        ids = parse_target_ids(args.target_ids)
        hosts = [build_pod_hostname(args, node_id) for node_id in ids]

    else:
        if args.end_id < args.start_id:
            raise ValueError("--end-id must be >= --start-id")

        ids = list(range(args.start_id, args.end_id + 1))
        hosts = [build_pod_hostname(args, node_id) for node_id in ids]

    targets = await asyncio.gather(
        *[make_target(host, args.port) for host in hosts]
    )

    logging.info(
        "resolved per-node targets count=%d hosts=%s",
        len(targets),
        ",".join(target.host for target in targets),
    )

    return list(targets)


async def send_libp2p_msg(
    session: aiohttp.ClientSession,
    args: argparse.Namespace,
    stats: Stats,
    target: Target,
    message_index: int,
    worker_id: Optional[int] = None,
) -> None:
    headers = {"Content-Type": "application/json"}

    body = {
        "topic": args.pubsub_topic,
        "msgSize": args.msg_size_bytes,
        "version": 1,
    }

    start = time.time()

    try:
        async with session.post(
            target.url,
            json=body,
            headers=headers,
            timeout=args.request_timeout,
        ) as response:
            elapsed_ms = (time.time() - start) * 1000.0
            response_text = await response.text()

            ok = response.status == 200
            await stats.record(ok)
            snap = await stats.snapshot()

            logging.info(
                "worker=%s message=%d target_host=%s target_ip=%s status=%d "
                "elapsed_ms=%.2f success=%d failure=%d total=%d success_rate=%.2f "
                "response=%s",
                worker_id,
                message_index,
                target.host,
                target.ip,
                response.status,
                elapsed_ms,
                snap["success"],
                snap["failure"],
                snap["total"],
                snap["success_rate"],
                response_text[:300],
            )

    except Exception as exc:
        elapsed_ms = (time.time() - start) * 1000.0

        await stats.record(False)
        snap = await stats.snapshot()

        logging.warning(
            "worker=%s message=%d target_host=%s target_ip=%s exception=%s "
            "elapsed_ms=%.2f success=%d failure=%d total=%d success_rate=%.2f",
            worker_id,
            message_index,
            target.host,
            target.ip,
            repr(exc),
            elapsed_ms,
            snap["success"],
            snap["failure"],
            snap["total"],
            snap["success_rate"],
        )


async def run_global_mode(
    args: argparse.Namespace,
    session: aiohttp.ClientSession,
    stats: Stats,
) -> None:
    background_tasks = set()
    start_time = time.time()
    message_index = 0

    while True:
        if args.messages is not None and message_index >= args.messages:
            break

        if (
            args.duration_seconds is not None
            and time.time() - start_time >= args.duration_seconds
        ):
            break

        target = await resolve_target_global(args, message_index)

        task = asyncio.create_task(
            send_libp2p_msg(
                session=session,
                args=args,
                stats=stats,
                target=target,
                message_index=message_index,
                worker_id=None,
            )
        )

        background_tasks.add(task)
        task.add_done_callback(background_tasks.discard)

        message_index += 1

        await asyncio.sleep(args.delay_seconds)

    if background_tasks:
        await asyncio.gather(*background_tasks)


async def per_node_worker(
    worker_id: int,
    target: Target,
    args: argparse.Namespace,
    session: aiohttp.ClientSession,
    stats: Stats,
) -> None:
    """
    Send messages to one selected node.

    Example:
      messages_per_node = 1000
      rate_per_node = 5

    This worker sends 1000 messages to its target node at 5 msg/s.

    All per-node workers run in parallel.
    """

    if args.rate_per_node is not None:
        if args.rate_per_node <= 0:
            raise ValueError("--rate-per-node must be > 0")

        delay_seconds = 1.0 / args.rate_per_node
    else:
        delay_seconds = args.delay_seconds

    start_time = time.time()
    message_index = 0

    while True:
        if (
            args.messages_per_node is not None
            and message_index >= args.messages_per_node
        ):
            break

        if (
            args.duration_seconds is not None
            and time.time() - start_time >= args.duration_seconds
        ):
            break

        await send_libp2p_msg(
            session=session,
            args=args,
            stats=stats,
            target=target,
            message_index=message_index,
            worker_id=worker_id,
        )

        message_index += 1

        await asyncio.sleep(delay_seconds)

    logging.info(
        "worker=%d target=%s finished local_messages=%d",
        worker_id,
        target.host,
        message_index,
    )


async def run_per_node_mode(
    args: argparse.Namespace,
    session: aiohttp.ClientSession,
    stats: Stats,
) -> None:
    targets = await get_per_node_targets(args)

    if not targets:
        raise RuntimeError("No targets selected for per-node mode")

    workers = [
        asyncio.create_task(
            per_node_worker(
                worker_id=i,
                target=target,
                args=args,
                session=session,
                stats=stats,
            )
        )
        for i, target in enumerate(targets)
    ]

    await asyncio.gather(*workers)


async def main(args: argparse.Namespace) -> None:
    stats = Stats()
    start_time = time.time()

    timeout = aiohttp.ClientTimeout(total=args.request_timeout)

    connector = aiohttp.TCPConnector(
        ttl_dns_cache=300,
    )

    async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
        if args.load_mode == "global":
            await run_global_mode(args, session, stats)

        elif args.load_mode == "per-node":
            await run_per_node_mode(args, session, stats)

        else:
            raise ValueError(f"Unsupported load mode: {args.load_mode}")

    elapsed_s = time.time() - start_time
    snap = await stats.snapshot()

    logging.info(
        "finished load_mode=%s elapsed_s=%.2f success=%d failure=%d total=%d success_rate=%.2f",
        args.load_mode,
        elapsed_s,
        snap["success"],
        snap["failure"],
        snap["total"],
        snap["success_rate"],
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
        "-p",
        "--port",
        type=int,
        default=8645,
        help="test node HTTP publish port",
    )

    parser.add_argument(
        "--load-mode",
        choices=["global", "per-node"],
        default="global",
        help=(
            "global = one global stream of messages; "
            "per-node = one stream per selected target node, all in parallel"
        ),
    )

    # Global mode target selection.
    parser.add_argument(
        "--peer-selection",
        choices=["service", "fixed", "round-robin", "random-range"],
        default="service",
        help="Target selection mode for global mode",
    )

    parser.add_argument(
        "--service-host",
        type=str,
        default="nimp2p-service",
        help="Service hostname used by peer-selection=service",
    )

    parser.add_argument(
        "--fixed-id",
        type=int,
        default=0,
        help="Target node ID used by peer-selection=fixed",
    )

    parser.add_argument(
        "--start-id",
        type=int,
        default=0,
        help="Start node ID for round-robin, random-range, or per-node default target range",
    )

    parser.add_argument(
        "--end-id",
        type=int,
        default=0,
        help="End node ID for round-robin, random-range, or per-node default target range",
    )

    # Hostname construction.
    parser.add_argument(
        "--pod-prefix",
        type=str,
        default="nim-libp2p",
        help="StatefulSet pod prefix, e.g. nim-libp2p",
    )

    parser.add_argument(
        "--pod-domain",
        type=str,
        default="",
        help=(
            "Optional pod DNS suffix. Example: "
            "nimp2p-service"
        ),
    )

    # Load amount / rate.
    parser.add_argument(
        "-m",
        "--messages",
        type=int,
        default=None,
        help="Total messages for global mode",
    )

    parser.add_argument(
        "--messages-per-node",
        type=int,
        default=None,
        help="Messages sent to each selected node in per-node mode",
    )

    parser.add_argument(
        "--duration-seconds",
        type=float,
        default=None,
        help="Run duration. Can be used in global or per-node mode.",
    )

    parser.add_argument(
        "-d",
        "--delay-seconds",
        type=float,
        default=1.0,
        help=(
            "Delay between messages. In per-node mode this is per node "
            "unless --rate-per-node is set."
        ),
    )

    parser.add_argument(
        "--rate-per-node",
        type=float,
        default=None,
        help=(
            "Per-node send rate in messages/second. "
            "Only applies to per-node mode and overrides --delay-seconds."
        ),
    )

    # Per-node target selection.
    parser.add_argument(
        "--target-ids",
        type=str,
        default="",
        help=(
            "Per-node mode target IDs. Examples: "
            "0, 0-9, 0-9,20,25-30"
        ),
    )

    parser.add_argument(
        "--target-hosts",
        type=str,
        default="",
        help=(
            "Per-node mode explicit target hostnames, comma-separated. "
            "Example: nim-libp2p-slow-0,nim-libp2p-1,nim-libp2p-2"
        ),
    )

    # HTTP settings.
    parser.add_argument(
        "--request-timeout",
        type=float,
        default=30.0,
        help="HTTP request timeout in seconds",
    )

    args = parser.parse_args()

    if args.load_mode == "global":
        if args.messages is None and args.duration_seconds is None:
            raise ValueError(
                "global mode requires --messages or --duration-seconds"
            )

    if args.load_mode == "per-node":
        if args.messages_per_node is None and args.duration_seconds is None:
            raise ValueError(
                "per-node mode requires --messages-per-node or --duration-seconds"
            )

        if args.target_hosts and args.target_ids:
            raise ValueError(
                "Use either --target-hosts or --target-ids, not both"
            )

    return args


if __name__ == "__main__":
    parsed_args = parse_args()
    logging.info("%s", parsed_args)
    asyncio.run(main(parsed_args))