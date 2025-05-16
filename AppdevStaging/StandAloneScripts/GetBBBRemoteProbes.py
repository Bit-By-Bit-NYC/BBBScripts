import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
import requests
import json
import getpass

prtg_url = "https://monitorbbb.eastus2.cloudapp.azure.com/api/table.json"


# Prompt for API key using getpass for security
apikey = getpass.getpass("Enter your PRTG API key: ")


params = {
    "content": "probes",
    "columns": "objid,name,host",
    "apikey": apikey,
    "count": "*"
}

try:
    # First, get the list of remote probes
    response = requests.get(prtg_url, params=params, verify=False)
    response.raise_for_status()

    data = response.json()

    if "probes" in data:
        for probe in data["probes"]:
            probe_id = probe["objid"]
            probe_name = probe["name"]
            probe_host = probe.get("host", "Unknown Host")
            
            print(f"Probe Name: {probe_name}, Hostname: {probe_host}")

    else:
        print("No probe data found in the response.")

except requests.exceptions.RequestException as e:
    print(f"Error during API request: {e}")
except json.JSONDecodeError as e:
    print(f"Error parsing JSON: {e}")
