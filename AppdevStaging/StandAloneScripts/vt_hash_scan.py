import csv
import requests
import time

# --- Configuration ---
API_KEY = '876962b9f7f33f4f3aca29777b7fcb5e68143ab3db6808150f614581d8254a42'
VT_URL = 'https://www.virustotal.com/api/v3/files/{}'
HEADERS = {'x-apikey': API_KEY}
INPUT_CSV = 'bin_hashes.csv'
OUTPUT_CSV = 'vt_results.csv'

def query_virustotal(hash_value):
    try:
        response = requests.get(VT_URL.format(hash_value), headers=HEADERS)
        if response.status_code == 200:
            data = response.json()
            stats = data.get('data', {}).get('attributes', {}).get('last_analysis_stats', {})
            return stats.get('malicious', 0), stats.get('suspicious', 0), stats.get('undetected', 0)
        elif response.status_code == 404:
            return 'Not Found', '', ''
        else:
            print(f"Error {response.status_code} for hash {hash_value}")
            return 'Error', '', ''
    except Exception as e:
        print(f"Exception while querying {hash_value}: {e}")
        return 'Error', '', ''

results = []

with open(INPUT_CSV, newline='') as infile:
    reader = csv.DictReader(infile)
    for row in reader:
        # Skip extra header rows or blanks
        if row['Hash'].strip().lower() == 'hash' or not row['Hash'].strip():
            continue

        hash_value = row['Hash'].strip()
        path = row['Path'].strip()
        print(f"Checking {path}...")

        malicious, suspicious, undetected = query_virustotal(hash_value)

        # Print only if flagged as malicious
        if isinstance(malicious, int) and malicious > 0:
            print(f"⚠️ MALICIOUS: {path}")
            print(f"   Hash: {hash_value}")
            print(f"   Malicious: {malicious}, Suspicious: {suspicious}, Undetected: {undetected}")

        results.append({
            'Path': path,
            'Hash': hash_value,
            'Malicious': malicious,
            'Suspicious': suspicious,
            'Undetected': undetected
        })

        # Wait 16s to respect free-tier rate limits (4 requests/minute)
        time.sleep(16)

# Save results to file
with open(OUTPUT_CSV, 'w', newline='') as outfile:
    fieldnames = ['Path', 'Hash', 'Malicious', 'Suspicious', 'Undetected']
    writer = csv.DictWriter(outfile, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(results)

print("\n✅ Scan complete. Results saved to:", OUTPUT_CSV)