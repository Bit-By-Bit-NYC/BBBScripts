import socket
import requests
import sys
import json

# Define Unicode symbols for status
CHECK_MARK = "✅"
CROSS_MARK = "❌"

def resolve_hostname(hostname):
    """Resolves a hostname to a list of IP addresses."""
    ip_list = []
    try:
        # gethostbyname_ex returns (hostname, aliaslist, ipaddrlist)
        _, _, ip_list = socket.gethostbyname_ex(hostname)
        return ip_list
    except socket.gaierror as e:
        print(f"Error resolving hostname {hostname}: {e}")
        return []

def get_rdns_hostname(ip_address):
    """Performs a reverse DNS lookup for an IP address."""
    try:
        # gethostbyaddr returns (hostname, aliaslist, ipaddrlist)
        hostname, _, _ = socket.gethostbyaddr(ip_address)
        return hostname
    except socket.herror:
        return "N/A" # Return N/A if rDNS lookup fails

def get_ip_info(ip_address):
    """Gets geolocation and organization info for an IP using ip-api.com."""
    try:
        response = requests.get(f"http://ip-api.com/json/{ip_address}")
        response.raise_for_status() # Raise an exception for bad status codes
        data = response.json()
        if data['status'] == 'success':
            return {
                'country': data.get('country', 'N/A'),
                'org': data.get('org', 'N/A')
            }
        else:
            return {
                'country': 'N/A',
                'org': data.get('message', 'Error') # Show error message if status is not success
            }
    except requests.exceptions.RequestException as e:
        return {
            'country': 'Error',
            'org': f"Request Error: {e}"
        }
    except json.JSONDecodeError:
         return {
            'country': 'Error',
            'org': 'JSON Decode Error'
        }


def main():
    if len(sys.argv) != 2:
        print("Usage: python dns_dashboard_check.py <hostname>")
        sys.exit(1)

    hostname = sys.argv[1]
    print(f"                            Checking DNS resolution for : {hostname}\n")

    ip_addresses = resolve_hostname(hostname)

    if not ip_addresses:
        sys.exit(1)

    # Print table header
    print(f"{'IP':<18} {'rDNS Hostname':<50} {'Country':<8} {'Org':<40} {'Status':<20}")
    print("-" * 18 + " " + "-" * 50 + " " + "-" * 8 + " " + "-" * 40 + " " + "-" * 20)

    for ip in ip_addresses:
        rdns = get_rdns_hostname(ip)
        ip_info = get_ip_info(ip)
        country = ip_info['country']
        org = ip_info['org']

        status_symbol = CROSS_MARK
        status_text = "Bad : Non-US"

        if country == "United States":
            status_symbol = CHECK_MARK
            status_text = "Good"

        # Print row data, ensuring alignment
        print(f"{ip:<18} {rdns:<50} {country:<8} {org:<40} {status_symbol} {status_text}")

if __name__ == "__main__":
    main()
