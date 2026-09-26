#!/usr/bin/env python3
import os
import sys
import json
import time
import datetime
import argparse
import subprocess
import shutil
import threading
import logging
import psutil
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

import MetaTrader5 as mt5


def is_wine():
    """Detect if we are running under Wine compatibility layer."""
    import ctypes
    try:
        return hasattr(ctypes.windll.ntdll, 'wine_get_version')
    except Exception:
        pass
    for env_var in ["WINEPREFIX", "WINELOADERNOEXEC", "WINEARCH"]:
        if env_var in os.environ:
            return True
    return False


def update_ini_template(template_content, login, password, server, expert=None, symbol=None, period=None):
    lines = template_content.splitlines()
    new_lines = []
    in_common = False
    in_startup = False
    
    updated_common_fields = {"login": False, "password": False, "server": False}
    updated_startup_fields = {"expert": False, "symbol": False, "period": False}
    
    for line in lines:
        stripped = line.strip()
        
        if stripped.startswith("[") and stripped.endswith("]"):
            section_name = stripped[1:-1].strip().lower()
            
            if in_common:
                for key in ["login", "password", "server"]:
                    if not updated_common_fields[key]:
                        val = login if key == "login" else (password if key == "password" else server)
                        new_lines.append(f"{key.capitalize()}={val}")
                        updated_common_fields[key] = True
                in_common = False
                
            if in_startup:
                for key, val in [("expert", expert), ("symbol", symbol), ("period", period)]:
                    if val is not None and not updated_startup_fields[key]:
                        new_lines.append(f"{key.capitalize()}={val}")
                        updated_startup_fields[key] = True
                in_startup = False
                
            if section_name == "common":
                in_common = True
            elif section_name == "startup":
                in_startup = True
        
        if in_common and "=" in line and not stripped.startswith(";"):
            key, val = line.split("=", 1)
            key_stripped = key.strip().lower()
            if key_stripped == "login":
                left_side = key.split('=')[0]
                new_lines.append(f"{left_side}={login}")
                updated_common_fields["login"] = True
                continue
            elif key_stripped == "password":
                left_side = key.split('=')[0]
                new_lines.append(f"{left_side}={password}")
                updated_common_fields["password"] = True
                continue
            elif key_stripped == "server":
                left_side = key.split('=')[0]
                new_lines.append(f"{left_side}={server}")
                updated_common_fields["server"] = True
                continue
                
        if in_startup and "=" in line and not stripped.startswith(";"):
            key, val = line.split("=", 1)
            key_stripped = key.strip().lower()
            if key_stripped == "expert" and expert is not None:
                left_side = key.split('=')[0]
                new_lines.append(f"{left_side}={expert}")
                updated_startup_fields["expert"] = True
                continue
            elif key_stripped == "symbol" and symbol is not None:
                left_side = key.split('=')[0]
                new_lines.append(f"{left_side}={symbol}")
                updated_startup_fields["symbol"] = True
                continue
            elif key_stripped == "period" and period is not None:
                left_side = key.split('=')[0]
                new_lines.append(f"{left_side}={period}")
                updated_startup_fields["period"] = True
                continue
        
        new_lines.append(line)
        
    if in_common:
        for key in ["login", "password", "server"]:
            if not updated_common_fields[key]:
                val = login if key == "login" else (password if key == "password" else server)
                new_lines.append(f"{key.capitalize()}={val}")
                updated_common_fields[key] = True
                
    if in_startup:
        for key, val in [("expert", expert), ("symbol", symbol), ("period", period)]:
            if val is not None and not updated_startup_fields[key]:
                new_lines.append(f"{key.capitalize()}={val}")
                updated_startup_fields[key] = True
                
    return "\n".join(new_lines)


class MT5Worker:
    def __init__(self, login_id, password, server, terminal_path, clone_dir, 
                 api_base_url, api_key, user_id, script_code, config_template_path, sync_interval=30,
                 expert=None, symbol=None, timeframe=None):
        self.login_id = int(login_id)
        self.password = password
        self.server = server
        self.terminal_path = os.path.normpath(terminal_path)
        self.clone_dir = os.path.normpath(clone_dir)
        self.api_base_url = api_base_url.rstrip('/')
        self.api_key = api_key
        self.user_id = user_id
        self.script_code = script_code
        self.config_template_path = os.path.normpath(config_template_path) if config_template_path else None
        self.sync_interval = sync_interval
        
        # Load expert, symbol, timeframe from parameters or fallback to env variables / defaults
        self.expert = expert or os.environ.get("WORKER_EXPERT", "FCE")
        self.symbol = symbol or os.environ.get("WORKER_SYMBOL", "XAUUSD")
        self.timeframe = timeframe or os.environ.get("WORKER_TIMEFRAME", "M1")
        
        self.reported_tickets_file = os.path.join(self.clone_dir, "reported_tickets.json")
        self.reported_tickets = self._load_reported_tickets()
        
        self.last_connected_status = None
        self.reported_balance_tickets_file = os.path.join(self.clone_dir, "reported_balance_tickets.json")
        self.reported_balance_tickets = self._load_reported_balance_tickets()
        
        self.mt5_process = None
        self.stop_event = threading.Event()
        self.monitor_thread = None
        
        os.makedirs(self.clone_dir, exist_ok=True)
        log_file = os.path.join(self.clone_dir, f"worker_{self.login_id}.log")
        
        self.logger = logging.getLogger(f"Worker_{self.login_id}")
        self.logger.setLevel(logging.INFO)
        
        fh = logging.FileHandler(log_file, encoding="utf-8")
        fh.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
        self.logger.addHandler(fh)
        
        if sys.stdout is not None:
            sh = logging.StreamHandler(sys.stdout)
            sh.setFormatter(logging.Formatter(f'[Worker {self.login_id}] %(asctime)s - %(levelname)s - %(message)s'))
            self.logger.addHandler(sh)
        
        self.logger.info("Worker initialized.")
        if is_wine():
            self.logger.info("Wine environment detected.")
            if "DISPLAY" not in os.environ:
                self.logger.warning("Running in headless Wine environment (DISPLAY not set). "
                                    "MetaTrader 5 requires an active X11 display or virtual framebuffer (Xvfb) to launch successfully.")

    def _load_reported_tickets(self):
        """Load already synced trade ticket IDs from local JSON storage."""
        if os.path.exists(self.reported_tickets_file):
            try:
                with open(self.reported_tickets_file, "r") as f:
                    data = json.load(f)
                    return set(str(t) for t in data)
            except Exception:
                pass
        return set()

    def _save_reported_tickets(self):
        """Persist reported trade ticket IDs to local storage."""
        try:
            with open(self.reported_tickets_file, "w") as f:
                json.dump(list(self.reported_tickets), f)
        except Exception as e:
            self.logger.error(f"Failed to save reported tickets list: {e}")

    def _load_reported_balance_tickets(self):
        """Load already processed balance operation ticket IDs from local JSON storage."""
        if os.path.exists(self.reported_balance_tickets_file):
            try:
                with open(self.reported_balance_tickets_file, "r") as f:
                    data = json.load(f)
                    return set(str(t) for t in data)
            except Exception:
                pass
        return set()

    def _save_reported_balance_tickets(self):
        """Persist processed balance operation ticket IDs to local storage."""
        try:
            with open(self.reported_balance_tickets_file, "w") as f:
                json.dump(list(self.reported_balance_tickets), f)
        except Exception as e:
            self.logger.error(f"Failed to save reported balance tickets list: {e}")

    def _send_api_post(self, endpoint, data):
        """Helper to send authenticated POST request to Bhionex API."""
        url = f"{self.api_base_url}{endpoint}"
        req = Request(url, method="POST")
        req.add_header("x-bot-api-key", self.api_key)
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json")
        
        try:
            payload = json.dumps(data).encode("utf-8")
            with urlopen(req, data=payload, timeout=15) as res:
                response_body = res.read().decode("utf-8")
                return json.loads(response_body)
        except HTTPError as e:
            body = e.read().decode("utf-8")
            self.logger.error(f"API Error POST {endpoint} (HTTP {e.code}): {body}")
            try:
                return json.loads(body)
            except Exception:
                return {"success": False, "message": body}
        except URLError as e:
            self.logger.error(f"Network Connection Failed POST {endpoint}: {e.reason}")
            return {"success": False, "message": str(e.reason)}
        except Exception as e:
            self.logger.error(f"Unexpected API error POST {endpoint}: {e}")
            return {"success": False, "message": str(e)}

    def _has_executable(self):
        """Check if terminal executable is already in the clone directory."""
        for name in ["terminal64.exe", "terminal.exe"]:
            if os.path.isfile(os.path.join(self.clone_dir, name)):
                return True
        return False

    def launch_mt5(self):
        """Starts the MT5 terminal process in portable mode."""


        if not self._has_executable():
            master_dir = os.path.dirname(self.terminal_path)
            self.logger.info(f"Clone directory {self.clone_dir} does not contain terminal executable. Cloning structure from master: {master_dir}")
            if not os.path.isdir(master_dir):
                self.logger.error(f"Master MT5 directory '{master_dir}' does not exist. Cannot clone.")
                return False
            try:
                try:
                    shutil.copytree(master_dir, self.clone_dir, dirs_exist_ok=True)
                except TypeError:
                    for item in os.listdir(master_dir):
                        s = os.path.join(master_dir, item)
                        d = os.path.join(self.clone_dir, item)
                        if os.path.isdir(s):
                            shutil.copytree(s, d)
                        else:
                            shutil.copy2(s, d)
                self.logger.info(f"Successfully cloned master MT5 structure to {self.clone_dir}")
            except Exception as e:
                self.logger.error(f"Failed to clone master MT5 directory to clone dir: {e}")
                return False

        if self.config_template_path:
            if os.path.exists(self.config_template_path):
                try:
                    self.logger.info(f"Updating config.ini from template: {self.config_template_path}")
                    with open(self.config_template_path, "r", encoding="utf-8") as f:
                        template_content = f.read()
                    
                    updated_content = update_ini_template(
                        template_content, 
                        str(self.login_id), 
                        self.password, 
                        self.server,
                        expert=self.expert,
                        symbol=self.symbol,
                        period=self.timeframe
                    )
                    
                    dest_ini_path = os.path.join(self.clone_dir, "config.ini")
                    with open(dest_ini_path, "w", encoding="utf-8") as f:
                        f.write(updated_content)
                    self.logger.info(f"Successfully wrote config.ini to {dest_ini_path}")
                except Exception as e:
                    self.logger.error(f"Failed to generate config.ini from template: {e}")
                    return False
            else:
                self.logger.error(f"Config template path '{self.config_template_path}' does not exist.")
                return False
        else:
            self.logger.warning("No config template path provided. Skipping config.ini update.")

        # Clear chart profiles in MQL5/Profiles/Charts/ and Profiles/Charts/ to start with no open charts
        for charts_root in [
            os.path.join(self.clone_dir, "MQL5", "Profiles", "Charts"),
            os.path.join(self.clone_dir, "Profiles", "Charts")
        ]:
            if not os.path.isdir(charts_root):
                continue
            for profile_name in os.listdir(charts_root):
                profile_dir = os.path.join(charts_root, profile_name)
                if not os.path.isdir(profile_dir):
                    continue
                self.logger.info(f"Clearing chart profile: {profile_dir}")
                try:
                    for item in os.listdir(profile_dir):
                        item_path = os.path.join(profile_dir, item)
                        if os.path.isfile(item_path):
                            os.remove(item_path)
                except Exception as e:
                    self.logger.error(f"Failed to clear charts in {profile_dir}: {e}")

        self.logger.info(f"Launching MT5 terminal: {self.terminal_path}")
        executable = None
        for name in ["terminal64.exe", "terminal.exe"]:
            p = os.path.join(self.clone_dir, name)
            if os.path.isfile(p):
                executable = p
                break
        
        if not executable:
            if os.path.isfile(self.terminal_path):
                shutil_dest = os.path.join(self.clone_dir, os.path.basename(self.terminal_path))
                try:
                    shutil.copy2(self.terminal_path, shutil_dest)
                    executable = shutil_dest
                    self.logger.info(f"Copied terminal executable to {executable}")
                except Exception as e:
                    self.logger.error(f"Failed to copy terminal executable to clone dir: {e}")
                    return False
            else:
                self.logger.error("No valid MT5 terminal executable found in clone or master path.")
                return False


        # Clean up stale temp files or sockets left from previous abruptly terminated instances
        temp_dir = os.path.join(self.clone_dir, "temp")
        if os.path.isdir(temp_dir):
            try:
                shutil.rmtree(temp_dir, ignore_errors=True)
            except Exception:
                pass

        creation_flags = 0
        if os.name == "nt" and not is_wine():
            creation_flags = subprocess.CREATE_NEW_CONSOLE

        try:
            config_file_path = os.path.normpath(os.path.join(self.clone_dir, "config.ini"))
            if os.name == "nt":
                # Use a raw string on Windows/Wine to prevent subprocess from quoting the '/config:' prefix when the path contains spaces
                cmd_str = f'"{executable}" /portable /config:"{config_file_path}"'
                self.logger.info(f"Spawning MT5 with command line: {cmd_str}")
                self.mt5_process = subprocess.Popen(
                    cmd_str,
                    cwd=self.clone_dir,
                    creationflags=creation_flags
                )
            else:
                self.mt5_process = subprocess.Popen(
                    [executable, "/portable", f"/config:{config_file_path}"],
                    cwd=self.clone_dir,
                    creationflags=creation_flags
                )
            self.logger.info(f"MT5 terminal process spawned (PID: {self.mt5_process.pid})")
            
            # Allow time for MT5 to start up (Wine needs more time than Windows)
            startup_wait = 15 if is_wine() else 5
            self.logger.info(f"Waiting {startup_wait}s for MT5 terminal startup...")
            time.sleep(startup_wait)
            
            # Check if process died immediately
            if self.mt5_process.poll() is not None:
                self.logger.error(f"MT5 terminal process terminated prematurely with exit code: {self.mt5_process.returncode}")
                return False

            # Under Wine/Windows, terminal64.exe may fork into a child process and the parent may exit cleanly
            term_proc = self.get_terminal_process()
            if term_proc:
                self.logger.info(f"Active MT5 terminal process detected (PID: {term_proc.pid})")
            elif self.mt5_process.poll() is None:
                self.logger.info(f"Direct MT5 process still active (PID: {self.mt5_process.pid})")
            else:
                self.logger.error("No active MT5 terminal process detected after launch.")
                return False
            return True
        except Exception as e:
            self.logger.error(f"Failed to launch MT5 subprocess: {e}")
            return False

    def _log_terminal_diagnostics(self):
        """Read and log recent lines from MT5 terminal logs and spawn logs to aid diagnosis."""
        try:
            logs_dir = os.path.join(self.clone_dir, "logs")
            if os.path.isdir(logs_dir):
                log_files = sorted([f for f in os.listdir(logs_dir) if f.endswith(".log") and not f.startswith("metaeditor")])
                if log_files:
                    latest_log = os.path.join(logs_dir, log_files[-1])
                    for enc in ["utf-16le", "utf-8", "cp1252"]:
                        try:
                            with open(latest_log, "r", encoding=enc, errors="replace") as f:
                                lines = [line.strip() for line in f if line.strip()]
                                recent = lines[-15:]
                                if recent:
                                    self.logger.info(f"--- MT5 Internal Log ({os.path.basename(latest_log)}) ---")
                                    for l in recent:
                                        self.logger.info(f"  [MT5] {l}")
                            break
                        except Exception:
                            continue

            spawn_log = os.path.join(self.clone_dir, f"worker_{self.login_id}_spawn.log")
            if os.path.isfile(spawn_log):
                with open(spawn_log, "r", encoding="utf-8", errors="replace") as f:
                    lines = [line.strip() for line in f if line.strip()]
                    recent = lines[-15:]
                    if recent:
                        self.logger.info(f"--- Wine Spawn Log ({os.path.basename(spawn_log)}) ---")
                        for l in recent:
                            self.logger.info(f"  [Wine] {l}")
        except Exception as e:
            self.logger.debug(f"Diagnostics reader error: {e}")

    def connect_mt5(self):
        """Initializes connection to the MT5 terminal instance with timeout and retry logic."""
        self.logger.info("Initializing connection via MetaTrader5 API...")
        executable = None
        for name in ["terminal64.exe", "terminal.exe"]:
            p = os.path.join(self.clone_dir, name)
            if os.path.isfile(p):
                executable = p
                break

        if not executable:
            self.logger.error("No MT5 terminal executable found in clone directory for API connection.")
            return False

        # Attempt to bind to the terminal with retries and explicit timeout
        max_attempts = 4
        timeout_ms = 30000

        for attempt in range(1, max_attempts + 1):
            self.logger.info(f"Binding to MetaTrader5 API (attempt {attempt}/{max_attempts}, timeout {timeout_ms}ms)...")

            if not self.is_terminal_running():
                self.logger.error("Terminal process is not running. Aborting API binding attempt.")
                self._log_terminal_diagnostics()
                return False

            success = False
            # Stage 1: Try connecting directly to running terminal IPC without forcing login
            # (terminal was already started with /config:config.ini)
            try:
                success = mt5.initialize(
                    path=executable,
                    timeout=timeout_ms,
                    portable=True
                )
                if not success:
                    # Stage 2: Fallback with explicit credentials
                    self.logger.debug("Direct initialize returned False, attempting with credentials...")
                    success = mt5.initialize(
                        path=executable,
                        login=self.login_id,
                        password=self.password,
                        server=self.server,
                        timeout=timeout_ms,
                        portable=True
                    )
            except Exception as e:
                self.logger.error(f"Exception during mt5.initialize(): {e}")
                success = False

            if success:
                self.logger.info("Successfully bound to MetaTrader5 API.")
                # Verify account connection status
                acc = mt5.account_info()
                if acc is None or acc.login != self.login_id:
                    self.logger.info(f"Account not active on terminal (current: {acc.login if acc else 'None'}). Logging into {self.login_id}...")
                    if not mt5.login(self.login_id, password=self.password, server=self.server, timeout=timeout_ms):
                        err = mt5.last_error()
                        self.logger.warning(f"mt5.login() failed: {err}")
                    else:
                        self.logger.info(f"Successfully logged into MT5 account {self.login_id}.")
                return True
            else:
                err = mt5.last_error()
                self.logger.warning(f"MetaTrader5 initialization attempt {attempt} failed: {err}")
                self._log_terminal_diagnostics()
                if attempt < max_attempts:
                    time.sleep(5)

        self.logger.error(f"Failed to bind to MetaTrader5 API after {max_attempts} attempts.")
        self._log_terminal_diagnostics()
        return False

    def get_terminal_process(self):
        """Finds any active MT5 terminal process running from this clone directory."""
        try:
            my_pid = os.getpid()
            clone_dir_abs = os.path.abspath(self.clone_dir).lower()
            clone_name = os.path.basename(self.clone_dir).lower()
            for proc in psutil.process_iter(['pid', 'name', 'exe', 'cmdline']):
                try:
                    if proc.info.get('pid') == my_pid:
                        continue
                    exe = proc.info.get('exe')
                    if exe and os.path.abspath(exe).lower().startswith(clone_dir_abs):
                        return proc
                    cmdline = proc.info.get('cmdline') or []
                    cmdline_str = " ".join(cmdline).lower()
                    if "worker.py" in cmdline_str:
                        continue
                    name = (proc.info.get('name') or '').lower()
                    if "terminal" in name or "wine" in name:
                        if ("terminal64.exe" in cmdline_str or "terminal.exe" in cmdline_str) and (clone_dir_abs in cmdline_str or clone_name in cmdline_str):
                            return proc
                except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                    pass
        except Exception as e:
            self.logger.debug(f"Error searching for terminal process: {e}")
        return None

    def is_terminal_running(self):
        """Checks if the MT5 terminal process for this clone is currently running."""
        # 1. Direct subprocess check
        if self.mt5_process is not None and self.mt5_process.poll() is None:
            return True
            
        # 2. Check via psutil (handles detached/forked processes in Wine)
        proc = self.get_terminal_process()
        if proc is not None and proc.is_running():
            return True
            
        # 3. Check via MT5 API IPC connection
        try:
            if mt5.terminal_info() is not None:
                return True
        except Exception:
            pass
            
        return False

    def check_connection(self):
        """Checks if terminal is online and logged in."""
        try:
            t_info = mt5.terminal_info()
            a_info = mt5.account_info()
            
            if t_info is None or a_info is None:
                return False
                
            return bool(t_info.connected)
        except Exception as e:
            self.logger.error(f"Error checking terminal connection: {e}")
            return False

    def sync_closed_trades(self):
        """Fetch closed trades from history and report them to the Bhionex API."""
        self.logger.info("Checking MT5 deal history for closed trades...")
        
        now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
        date_from = now - datetime.timedelta(days=30)
        date_to = now + datetime.timedelta(days=5)
        
        deals = mt5.history_deals_get(date_from, date_to)
        if deals is None:
            err = mt5.last_error()
            self.logger.error(f"Failed to retrieve deal history: {err}")
            return
            
        self.logger.debug(f"Retrieved {len(deals)} total deals from history.")
        new_trades_reported = 0
        
        for deal in deals:
            if deal.entry in (1, 2, 3) and str(deal.ticket) not in self.reported_tickets:
                self.logger.info(f"Found new closed deal: Ticket={deal.ticket}, Symbol={deal.symbol}, Profit={deal.profit}")
                
                entry_price = 0.0
                opened_at = deal.time
                
                position_id = deal.position_id
                pos_deals = mt5.history_deals_get(position=position_id)
                if pos_deals:
                    for pd in pos_deals:
                        if pd.entry == 0:
                            entry_price = pd.price
                            opened_at = pd.time
                            break
                
                net_pl = deal.profit + deal.commission + deal.swap
                
                trade_payload = {
                    "userId": self.user_id,
                    "scriptCode": self.script_code,
                    "externalTradeId": f"MT5-{deal.ticket}",
                    "symbol": deal.symbol,
                    "tradeType": "buy" if deal.type == 0 else "sell",
                    "lotSize": deal.volume,
                    "entryPrice": entry_price,
                    "exitPrice": deal.price,
                    "stopLoss": 0,
                    "takeProfit": 0,
                    "openedAt": datetime.datetime.fromtimestamp(opened_at, datetime.timezone.utc).isoformat(),
                    "closedAt": datetime.datetime.fromtimestamp(deal.time, datetime.timezone.utc).isoformat(),
                    "status": "closed",
                    "profitLoss": net_pl,
                    "commission": deal.commission,
                    "swap": deal.swap,
                    "balanceAfterTrade": mt5.account_info().balance if mt5.account_info() else 0.0,
                    "mt5AccountStatus": "connected"
                }
                
                res = self._send_api_post("/api/bot/trades", trade_payload)
                if res.get("success"):
                    self.logger.info(f"Successfully reported trade ticket {deal.ticket} to API.")
                    self.reported_tickets.add(str(deal.ticket))
                    new_trades_reported += 1
                else:
                    self.logger.error(f"Failed to report trade {deal.ticket}: {res.get('message')}")
                    
        if new_trades_reported > 0:
            self._save_reported_tickets()

    def sync_balance_operations(self):
        """Check for new balance operations (deposits/withdrawals) in history.
        If any new ones are detected, trigger sync_account_status.
        """
        self.logger.info("Checking MT5 deal history for balance operations (deposits/withdrawals)...")
        
        now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
        date_from = now - datetime.timedelta(days=30)
        date_to = now + datetime.timedelta(days=5)
        
        deals = mt5.history_deals_get(date_from, date_to)
        if deals is None:
            err = mt5.last_error()
            self.logger.error(f"Failed to retrieve deal history for balance check: {err}")
            return
            
        new_balance_ops = 0
        for deal in deals:
            # Check if this is a balance operation (deposit/withdrawal) and not yet reported
            deal_type_balance = getattr(mt5, "DEAL_TYPE_BALANCE", 2)
            if deal.type == deal_type_balance and str(deal.ticket) not in self.reported_balance_tickets:
                self.logger.info(f"Found new balance operation: Ticket={deal.ticket}, Profit/Amount={deal.profit}, Comment={deal.comment}")
                self.reported_balance_tickets.add(str(deal.ticket))
                new_balance_ops += 1
                
        if new_balance_ops > 0:
            self._save_reported_balance_tickets()
            self.logger.info(f"Detected {new_balance_ops} new balance operation(s). Triggering account summary sync.")
            # self.sync_account_status(is_connected=True)

    def sync_account_status(self, is_connected):
        """Sends account metrics summary to the Bhionex API."""
        self.logger.info("Reporting account summary...")
        acc_info = mt5.account_info()
        
        status_payload = {
            "userId": self.user_id,
            "scriptCode": self.script_code,
            "mt5AccountStatus": "connected" if is_connected else "disconnected"
        }
        
        if is_connected and acc_info:
            status_payload.update({
                "currentBalance": acc_info.balance,
                "investedAmount": max(0.0, acc_info.equity - acc_info.balance) if acc_info.equity > acc_info.balance else 0.0,
                "lastSyncAt": datetime.datetime.now(datetime.timezone.utc).isoformat()
            })
        else:
            status_payload.update({
                "currentBalance": 0.0,
                "investedAmount": 0.0,
                "lastSyncAt": datetime.datetime.now(datetime.timezone.utc).isoformat()
            })
            
        res = self._send_api_post("/api/bot/trading-summary", status_payload)
        if res.get("success"):
            self.logger.info("Account summary successfully synced.")
        else:
            self.logger.error(f"Failed to sync account summary: {res.get('message')}")

    def monitor_loop(self):
        """Main loop managing terminal state and calling checks."""
        self.logger.info("Starting monitoring loop...")
        consecutive_failures = 0
        
        if not self.launch_mt5() or not self.connect_mt5():
            consecutive_failures = 5
            
        while not self.stop_event.is_set():
            try:
                proc_running = self.is_terminal_running()
                
                connected = False
                if proc_running:
                    connected = self.check_connection()
                    if not connected:
                        # If the process is alive but terminal_info is None, try reconnecting API
                        try:
                            if mt5.terminal_info() is None:
                                self.logger.warning("Terminal process is alive but MT5 API disconnected. Attempting API reconnect...")
                                if self.connect_mt5():
                                    connected = self.check_connection()
                        except Exception:
                            pass
                    
                if not proc_running or not connected:
                    consecutive_failures += 1
                    self.logger.warning(f"Connection/Process failure detected. Streak: {consecutive_failures}")
                    
                    if not proc_running:
                        self.logger.warning("MT5 process has terminated.")
                    elif not connected:
                        self.logger.warning("MT5 terminal is disconnected from broker.")
                else:
                    consecutive_failures = 0
                    
                if consecutive_failures >= 3:
                    self.logger.error("Multiple connection/process failures. Restarting terminal...")
                    self.restart_terminal()
                    consecutive_failures = 0
                    time.sleep(10)
                    continue
                    
                if connected != self.last_connected_status:
                    # self.sync_account_status(is_connected=connected)
                    self.last_connected_status = connected
                    
                if connected:
                    self.sync_closed_trades()
                    self.sync_balance_operations()
                    
            except Exception as e:
                self.logger.error(f"Error in monitor loop iteration: {e}")
                
            self.stop_event.wait(self.sync_interval)
            
        # Cleanup on stop
        self.logger.info("Stopping worker processes...")
        try:
            mt5.shutdown()
        except Exception:
            pass
        self.kill_process()
        self.logger.info("Worker stopped.")

    def restart_terminal(self):
        """Terminates active process and restarts the terminal."""
        self.logger.info("Executing terminal restart sequence...")
        try:
            mt5.shutdown()
        except Exception:
            pass
        self.kill_process()
        time.sleep(2)
        
        if self.launch_mt5():
            self.connect_mt5()

    def kill_process(self):
        """Forcibly terminates the MT5 terminal process and any processes running from clone_dir."""
        # 1. Terminate tracked subprocess handle if alive
        if self.mt5_process:
            self.logger.info(f"Terminating tracked terminal process (PID: {self.mt5_process.pid})...")
            try:
                if self.mt5_process.poll() is None:
                    self.mt5_process.terminate()
                    self.mt5_process.wait(timeout=3)
                    self.logger.info("Tracked process terminated.")
            except Exception:
                try:
                    self.mt5_process.kill()
                except Exception:
                    pass
            finally:
                self.mt5_process = None

        # 2. Terminate any terminal processes running from this clone directory (handles Wine child/forked processes)
        try:
            my_pid = os.getpid()
            clone_dir_abs = os.path.abspath(self.clone_dir).lower()
            clone_name = os.path.basename(self.clone_dir).lower()
            for proc in psutil.process_iter(['pid', 'name', 'exe', 'cmdline']):
                try:
                    if proc.info.get('pid') == my_pid:
                        continue
                    cmdline = proc.info.get('cmdline') or []
                    cmdline_str = " ".join(cmdline).lower()
                    if "worker.py" in cmdline_str:
                        continue
                    exe = proc.info.get('exe')
                    name = (proc.info.get('name') or '').lower()

                    matches_dir = exe and os.path.abspath(exe).lower().startswith(clone_dir_abs)
                    matches_cmd = ("terminal" in name or "wine" in name) and ("terminal64.exe" in cmdline_str or "terminal.exe" in cmdline_str) and (clone_dir_abs in cmdline_str or clone_name in cmdline_str)

                    if matches_dir or matches_cmd:
                        self.logger.info(f"Terminating cloned MT5 process (PID: {proc.pid})...")
                        proc.kill()
                        proc.wait(timeout=3)
                        self.logger.info(f"Process {proc.pid} terminated cleanly.")
                except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.TimeoutExpired, OSError):
                    pass
        except Exception as e:
            self.logger.error(f"Error terminating processes in clone dir: {e}")

    def start(self):
        """Launches the worker thread."""
        if self.monitor_thread and self.monitor_thread.is_alive():
            self.logger.warning("Worker is already running.")
            return
            
        self.stop_event.clear()
        self.monitor_thread = threading.Thread(target=self.monitor_loop, name=f"Monitor_{self.login_id}")
        self.monitor_thread.daemon = True
        self.monitor_thread.start()
        self.logger.info("Worker thread started.")

    def stop(self):
        """Signals the worker thread to stop and waits for it to join."""
        if not self.monitor_thread or not self.monitor_thread.is_alive():
            self.logger.warning("Worker is not running.")
            return
            
        self.logger.info("Stopping worker...")
        self.stop_event.set()
        self.monitor_thread.join(timeout=15)
        self.logger.info("Worker stop sequence complete.")


def load_dotenv(dotenv_path=".env"):
    if not os.path.exists(dotenv_path):
        return False
    with open(dotenv_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, val = line.split("=", 1)
                key = key.strip()
                val = val.strip()
                if val.startswith('"') and val.endswith('"'):
                    val = val[1:-1]
                elif val.startswith("'") and val.endswith("'"):
                    val = val[1:-1]
                os.environ[key] = val
    return True

if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    dotenv_path = os.path.join(script_dir, ".env")
    load_dotenv(dotenv_path)

    parser = argparse.ArgumentParser(description="Standalone MT5 Account Worker")
    parser.add_argument("--login", required=True, help="MT5 login ID")
    parser.add_argument("--password", required=True, help="MT5 login password")
    parser.add_argument("--server", required=True, help="MT5 broker server name")
    parser.add_argument("--terminal-path", required=True, help="Path to master terminal64.exe template")
    parser.add_argument("--clone-dir", required=True, help="Path to this account's cloned folder")
    parser.add_argument("--api-base", required=True, help="Base url of the Bhionex API")
    parser.add_argument("--api-key", required=True, help="x-bot-api-key credential")
    parser.add_argument("--user-id", required=True, help="Bhionex userId mapping")
    parser.add_argument("--script-code", required=True, help="Active script code (e.g. SCRIPT_1)")
    parser.add_argument("--config-template", required=True, help="Path to config.ini template")
    parser.add_argument("--interval", type=int, default=30, help="Sync interval in seconds")
    parser.add_argument("--expert", help="MT5 Expert Advisor name")
    parser.add_argument("--symbol", help="MT5 Symbol")
    parser.add_argument("--timeframe", help="MT5 Timeframe / Period (e.g. M1, H1)")
    
    args = parser.parse_args()
    
    worker = MT5Worker(
        login_id=args.login,
        password=args.password,
        server=args.server,
        terminal_path=args.terminal_path,
        clone_dir=args.clone_dir,
        api_base_url=args.api_base,
        api_key=args.api_key,
        user_id=args.user_id,
        script_code=args.script_code,
        config_template_path=args.config_template,
        sync_interval=args.interval,
        expert=args.expert,
        symbol=args.symbol,
        timeframe=args.timeframe
    )
    
    worker.start()
    
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        if sys.stdout is not None:
            print("\nStopping standalone worker process...")
        worker.stop()
        if sys.stdout is not None:
            print("Exiting.")
