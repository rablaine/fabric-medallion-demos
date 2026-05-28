"""Contoso retail clickstream emitter.

Timer-triggered Azure Function that fires every TIMER_SCHEDULE (default
30 seconds) and pushes EVENTS_PER_FIRE (default 50) synthetic clickstream
events into a Fabric Eventstream CustomEndpoint source.

The Fabric Eventstream CustomEndpoint exposes an Event Hub-compatible
endpoint with a Fabric-managed SAS connection string. We authenticate with
that conn string (read from EVENTHUB_CONNECTION_STRING) rather than MSI:
tenant policy `EventHub_DisableLocalAuth_Modify` forbids SAS auth on Azure
Event Hubs, but the Fabric-managed endpoint is exempt because it isn't an
Azure EH namespace -- it's a Fabric Real-Time Hub managed pipe.

The conn string is populated at deploy time by deploy.ps1 after the
Eventstream is created (see Get-FabricEventstreamSourceConnectionString).
"""
from __future__ import annotations

import datetime as dt
import json
import logging
import os
import random
import uuid

import azure.functions as func
from azure.eventhub import EventData, EventHubProducerClient

# -----------------------------------------------------------------------------
# Configuration (all wired via app settings -- conn string set by deploy.ps1)
# -----------------------------------------------------------------------------
CONNECTION_STRING = os.environ["EVENTHUB_CONNECTION_STRING"]
SCHEDULE          = os.environ.get("TIMER_SCHEDULE", "*/30 * * * * *")
EVENTS_PER_FIRE   = int(os.environ.get("EVENTS_PER_FIRE", "50"))

# Demo dimensions -- small fixed sets keep downstream Eventstream/silver joins
# tractable. Customer/product IDs intentionally overlap with the seed notebook's
# ranges so analytic joins to retail.customers / retail.products work out of
# the box.
EVENT_TYPES = ["page_view", "product_view", "add_to_cart", "remove_from_cart",
               "checkout_start", "checkout_complete", "search"]
EVENT_TYPE_WEIGHTS = [0.45, 0.25, 0.10, 0.04, 0.06, 0.04, 0.06]
DEVICE_TYPES = ["desktop", "mobile", "tablet"]
DEVICE_WEIGHTS = [0.42, 0.50, 0.08]
CHANNELS = ["organic", "google_ads", "meta_ads", "email", "direct", "referral"]

# Reuse the producer across invocations (Functions reuses the Python process
# between firings). Conn string carries the EntityPath, so no name needed.
_producer = EventHubProducerClient.from_connection_string(CONNECTION_STRING)

app = func.FunctionApp()


def _make_event() -> dict:
    return {
        "event_id":    str(uuid.uuid4()),
        "event_ts":    dt.datetime.now(dt.timezone.utc).isoformat(),
        "event_type":  random.choices(EVENT_TYPES, weights=EVENT_TYPE_WEIGHTS, k=1)[0],
        "customer_id": random.randint(1, 5000),    # matches seed.customers range
        "product_id":  random.randint(1, 1500),    # matches seed.products range
        "session_id":  str(uuid.uuid4()),
        "device":      random.choices(DEVICE_TYPES, weights=DEVICE_WEIGHTS, k=1)[0],
        "channel":     random.choice(CHANNELS),
        "page_url":    f"/p/{random.randint(1, 1500)}",
    }


@app.function_name(name="ClickstreamTimer")
@app.timer_trigger(schedule=SCHEDULE, arg_name="timer", run_on_startup=False, use_monitor=False)
def clickstream_timer(timer: func.TimerRequest) -> None:
    """Emit a batch of synthetic clickstream events to Event Hubs."""
    if timer.past_due:
        logging.warning("ClickstreamTimer: past due, catching up")

    batch = _producer.create_batch()
    for _ in range(EVENTS_PER_FIRE):
        evt = _make_event()
        ed = EventData(json.dumps(evt))
        ed.properties = {"event_type": evt["event_type"]}
        try:
            batch.add(ed)
        except ValueError:
            # Batch full -- flush and start a new one.
            _producer.send_batch(batch)
            batch = _producer.create_batch()
            batch.add(ed)

    if len(batch) > 0:
        _producer.send_batch(batch)

    logging.info("ClickstreamTimer: sent %d events", EVENTS_PER_FIRE)
