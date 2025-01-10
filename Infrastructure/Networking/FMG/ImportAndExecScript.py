import requests
import json
import urllib3
import time
from colorama import Fore, Style, init

# Initialize colorama for colorized output
init(autoreset=True)

# Disable SSL warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configuration and script file paths
CONFIG_FILE = "config.txt"
SCRIPT_FILE = "script_to_upload.txt"

def read_config(file_path):
    """Read FortiManager configuration from a text file."""
    try:
        with open(file_path, "r") as file:
            config = {}
            for line in file:
                key, value = line.strip().split("=", 1)
                config[key.strip()] = value.strip()
            return config
    except FileNotFoundError:
        print(f"{Fore.RED}Error: Configuration file '{file_path}' not found.")
        exit(1)
    except ValueError:
        print(f"{Fore.RED}Error: Invalid format in configuration file '{file_path}'.")
        exit(1)

def fmg_request(url, method, params, session=None):
    """Send a request to the FortiManager."""
    payload = {
        "id": 1,
        "method": method,
        "params": params
    }
    if session:
        payload["session"] = session

    response = requests.post(url, json=payload, verify=False)  # SSL verification disabled
    response.raise_for_status()  # Raise an error for HTTP errors
    return response.json()

def main():
    try:
        # Read configuration
        config = read_config(CONFIG_FILE)
        FMG_IP = config["HOST"]
        USERNAME = config["USERNAME"]
        PASSWORD = config["PASSWORD"]
        SCRIPT_NAME = config["SCRIPT_NAME"]
        BASE_URL = f"https://{FMG_IP}/jsonrpc"

        # Read script content from file
        print(f"{Fore.CYAN}Reading script content from file: {SCRIPT_FILE}")
        try:
            with open(SCRIPT_FILE, "r") as file:
                script_content = file.read()
        except FileNotFoundError:
            print(f"{Fore.RED}Error: File '{SCRIPT_FILE}' not found.")
            return

        # Authenticate and get session token
        print(f"{Fore.CYAN}Authenticating...")
        login_params = [{
            "url": "/sys/login/user",
            "data": {
                "user": USERNAME,
                "passwd": PASSWORD
            }
        }]
        session_data = fmg_request(BASE_URL, "exec", login_params)
        session_token = session_data["session"]
        print(f"{Fore.GREEN}Authentication successful. Session token received.")

        # Get list of ADOMs
        print(f"{Fore.CYAN}Retrieving ADOMs...")
        adom_params = [{"url": "/dvmdb/adom"}]
        adom_data = fmg_request(BASE_URL, "get", adom_params, session_token)
        adoms = [adom["name"] for adom in adom_data["result"][0]["data"]]
        print(f"{Fore.GREEN}Found ADOMs: {', '.join(adoms)}")

        # Process each ADOM
        for adom in adoms:



            if adom.startswith("Forti"):
                    print(f"\n{Fore.YELLOW}Skipping ADOM: {adom}")
                    continue
            else:
                print(f"\n{Fore.YELLOW}Processing ADOM: {adom}")
            

            # Upload the script to FortiManager for this ADOM
            print(f"{Fore.CYAN}Uploading script to ADOM: {adom}...")
            upload_params = [{
                "url": f"/dvmdb/adom/{adom}/script",
                "data": {
                    "name": SCRIPT_NAME,
                    "desc": "Automated Script Execution",
                    "type": "cli",
                    "target": "remote_device",
                    "content": script_content
                }
            }]
            upload_response = fmg_request(BASE_URL, "add", upload_params, session_token)
            if upload_response["result"][0]["status"]["code"] == 0:
                print(f"{Fore.GREEN}Script uploaded successfully to ADOM: {adom}.")
            elif upload_response["result"][0]["status"]["message"] == "Object already exists":
                print(f"{Fore.GREEN}Script already exists in ADOM: {adom}.")
            else:
                print(f"{Fore.RED}Failed to upload script to ADOM: {adom} - Error Message: {upload_response["result"][0]["status"]["message"]}")
                continue

            # Get list of devices in the ADOM
            print(f"{Fore.CYAN}Retrieving devices in ADOM: {adom}...")
            device_params = [{"url": f"/dvmdb/adom/{adom}/device"}]
            device_data = fmg_request(BASE_URL, "get", device_params, session_token)
            devices = device_data["result"][0]["data"]
            #time.sleep(60)

            
            if True:
                # Execute script on each device
                # 20241204- Need to execute it against the local device as well as to the database so it is included in the next push
                for device in devices:
                    device_name = device["name"]
                    print(f"{Fore.BLUE}Executing script on device: {device_name}...")
                    execute_params = [{
                        "url": f"/dvmdb/adom/{adom}/script/execute",
                        "data": {
                            "adom": adom,
                            "script": SCRIPT_NAME,
                            "scope": [
                                {"name": device_name, "vdom": "root"}  # Adjust "root" if your vdom name is different
                            ]
                        }
                    }]
                    execute_response = fmg_request(BASE_URL, "exec", execute_params, session_token)
                    if execute_response["result"][0]["status"]["code"] == 0:
                        print(f"{Fore.GREEN}Script executed successfully on device: {device_name}")
                    else:
                        print(f"{Fore.RED}Failed to execute script on device: {device_name}")

        # Logout
        print(f"\n{Fore.CYAN}Logging out...")
        logout_params = [{"url": "/sys/logout"}]
        fmg_request(BASE_URL, "exec", logout_params, session_token)
        print(f"{Fore.GREEN}Logged out successfully.")

    except Exception as e:
        print(f"{Fore.RED}An error occurred: {e}")

if __name__ == "__main__":
    main()