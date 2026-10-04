#!/usr/bin/env python3
import os
import sys
import json
import subprocess
import uuid
import shutil
import time
import psutil
from flask import Flask, request, jsonify
from flask_cors import CORS


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


script_dir = os.path.dirname(os.path.abspath(__file__))
dotenv_path = os.path.join(script_dir, ".env")
load_dotenv(dotenv_path)

MASTER_MT5_DIR = os.environ.get("MASTER_MT5_DIR")
CLIENTS_DIR = os.environ.get("CLIENTS_DIR")
VALIDATION_TIMEOUT = int(os.environ.get("VALIDATION_TIMEOUT", 30))


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


def kill_processes_in_dir(target_dir):
    """Force kill any processes running from the target directory to allow clean deletion."""
    if not target_dir:
        return
    target_dir_abs = os.path.abspath(target_dir).lower()
    for proc in psutil.process_iter():
        try:
            exe = proc.exe()
            if exe and os.path.abspath(exe).lower().startswith(target_dir_abs):
                proc.kill()
                proc.wait(timeout=2)
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.TimeoutExpired, OSError, Exception):
            pass


def cleanup_temp_dir(temp_dir_path):
    """Clean up the temporary clone directory and all active processes running from it."""
    if not temp_dir_path or not os.path.exists(temp_dir_path):
        return
    kill_processes_in_dir(temp_dir_path)
    for _ in range(3):
        try:
            if os.path.exists(temp_dir_path):
                shutil.rmtree(temp_dir_path)
            break
        except Exception:
            time.sleep(1)
            kill_processes_in_dir(temp_dir_path)


def execute_validation(login, password, server, master_dir, clients_dir, temp_dir_path=None):
    """Perform MT5 credential validation in an isolated terminal clone."""
    if is_wine() and "DISPLAY" not in os.environ:
        raise RuntimeError("Running in headless Wine environment (DISPLAY not set). MetaTrader 5 requires an active X11 display or virtual framebuffer (Xvfb) to run.")

    if not temp_dir_path:
        temp_dir_name = f"validate_{login}_{uuid.uuid4().hex[:8]}"
        temp_dir_path = os.path.join(clients_dir, temp_dir_name)

    # 1. Clone master MT5
    try:
        try:
            shutil.copytree(master_dir, temp_dir_path, dirs_exist_ok=True)
        except TypeError:
            # Fallback for Python versions < 3.8
            for item in os.listdir(master_dir):
                s = os.path.join(master_dir, item)
                d = os.path.join(temp_dir_path, item)
                if os.path.isdir(s):
                    shutil.copytree(s, d)
                else:
                    shutil.copy2(s, d)
    except Exception as e:
        return {"valid": False, "error": f"Failed to create temporary clone: {e}"}

    executable = None
    for name in ["terminal64.exe", "terminal.exe"]:
        p = os.path.join(temp_dir_path, name)
        if os.path.isfile(p):
            executable = p
            break

    if not executable:
        shutil.rmtree(temp_dir_path, ignore_errors=True)
        return {"valid": False, "error": "Terminal executable not found in clone"}

    # 2. Validate credentials
    try:
        import MetaTrader5 as mt5
    except ImportError as e:
        cleanup_temp_dir(temp_dir_path)
        return {"valid": False, "error": f"MetaTrader5 package import failed: {e}"}

    success = mt5.initialize(
        path=executable,
        login=login,
        password=password,
        server=server,
        timeout=20000,
        portable=True
    )

    result = {"valid": False, "error": "Unknown initialization error"}

    if success:
        # MT5 might take a moment to establish broker connection
        time.sleep(1)
        t_info = mt5.terminal_info()
        if t_info and t_info.connected:
            a_info = mt5.account_info()
            equity = a_info.equity if a_info is not None else None
            result = {"valid": True, "equity": equity}
        else:
            result = {"valid": False, "error": "Invalid credentials or broker unreachable"}
    else:
        err = mt5.last_error()
        result = {"valid": False, "error": f"MT5 initialization failed: {err}"}

    # 3. Shutdown and cleanup
    try:
        mt5.shutdown()
    except Exception:
        pass

    time.sleep(2)  # Give MT5 time to gracefully exit
    kill_processes_in_dir(temp_dir_path)
    time.sleep(1)
    shutil.rmtree(temp_dir_path, ignore_errors=True)

    return result


def run_task_cli():
    """CLI task runner reading JSON from stdin and writing JSON result to stdout."""
    try:
        input_data = sys.stdin.read()
        if not input_data:
            print(json.dumps({"valid": False, "error": "No input data provided"}))
            sys.exit(1)

        data = json.loads(input_data)
        login = data.get("login")
        password = data.get("password")
        server = data.get("server")
        master_dir = data.get("master_dir")
        clients_dir = data.get("clients_dir")
        temp_dir_path = data.get("temp_dir_path")

        if not all([login, password, server, master_dir, clients_dir]):
            print(json.dumps({"valid": False, "error": "Missing required fields in payload"}))
            sys.exit(1)

        result = execute_validation(
            login=login,
            password=password,
            server=server,
            master_dir=master_dir,
            clients_dir=clients_dir,
            temp_dir_path=temp_dir_path
        )
        print(json.dumps(result))
        sys.exit(0)
    except Exception as e:
        print(json.dumps({"valid": False, "error": str(e)}))
        sys.exit(1)


# Flask Application Setup
app = Flask(__name__)
CORS(app)


@app.route('/', methods=['POST'])
@app.route('/validate', methods=['POST'])
def validate():
    data = request.get_json(force=True, silent=True)
    if not data:
        return jsonify({"valid": False, "error": "Invalid or missing JSON payload"}), 400

    login = data.get("loginId") if data.get("loginId") is not None else data.get("login")
    password = data.get("password")
    server = data.get("server")

    if not login or not password or not server:
        return jsonify({"valid": False, "error": "Missing login, password, or server"}), 400

    try:
        login = int(login)
    except (ValueError, TypeError):
        return jsonify({"valid": False, "error": "Login must be an integer"}), 400

    if not MASTER_MT5_DIR or not CLIENTS_DIR:
        return jsonify({"valid": False, "error": "Server configuration error: MASTER_MT5_DIR or CLIENTS_DIR not set"}), 500

    # Generate temp clone path in API to control/cleanup if timeout or error happens
    temp_dir_name = f"validate_{login}_{uuid.uuid4().hex[:8]}"
    temp_dir_path = os.path.normpath(os.path.join(CLIENTS_DIR, temp_dir_name))

    p = None
    try:
        # Launch isolated validation task subprocess using current script
        p = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--task"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )

        payload = json.dumps({
            "login": login,
            "password": password,
            "server": server,
            "master_dir": MASTER_MT5_DIR,
            "clients_dir": CLIENTS_DIR,
            "temp_dir_path": temp_dir_path
        })

        stdout, stderr = p.communicate(input=payload, timeout=VALIDATION_TIMEOUT)

        if p.returncode != 0:
            return jsonify({"valid": False, "error": "Validation process failed", "details": stderr.strip() or stdout.strip()}), 500

        try:
            result = json.loads(stdout.strip())
            return jsonify(result)
        except json.JSONDecodeError:
            return jsonify({"valid": False, "error": "Invalid response from validator task", "details": stdout.strip()}), 500

    except subprocess.TimeoutExpired:
        if p:
            p.kill()
            p.wait()
        return jsonify({"valid": False, "error": "Validation timed out"}), 504
    except Exception as e:
        if p:
            p.kill()
            p.wait()
        return jsonify({"valid": False, "error": str(e)}), 500
    finally:
        cleanup_temp_dir(temp_dir_path)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ["--task", "-t"]:
        run_task_cli()
        sys.exit(0)

    port = int(os.environ.get("VALIDATOR_PORT", 5001))
    threads = int(os.environ.get("VALIDATOR_THREADS", 4))

    if is_wine() and "DISPLAY" not in os.environ:
        print("[WARNING] Running in headless Wine environment (DISPLAY is not set).")
        print("          MetaTrader 5 requires an active X11 display or virtual framebuffer (Xvfb) for validation.")

    try:
        from waitress import serve
        print(f"Starting Validator API on port {port} (Production WSGI: Waitress, Threads: {threads})...")
        serve(app, host="0.0.0.0", port=port, threads=threads)
    except ImportError:
        print(f"Waitress not installed. Starting Validator API on port {port} (Flask Dev Server)...")
        app.run(host="0.0.0.0", port=port)
