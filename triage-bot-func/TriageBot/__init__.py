import os
import json
from openai import AzureOpenAI
import logging
import azure.functions as func
import pyodbc

# Setup OpenAI configuration
def get_openai_client():
    return AzureOpenAI(
        api_key=os.getenv("AZURE_OPENAI_KEY"),
        api_version=os.getenv("AZURE_OPENAI_VERSION"),
        azure_endpoint=os.getenv("AZURE_OPENAI_ENDPOINT")
    )

# Extract skills and a resolution from the ticket description
def extract_skills(problem_summary):
    client = get_openai_client()
    deployment = os.getenv("AZURE_OPENAI_DEPLOYMENT")

    prompt = f"""
You are a helpdesk AI assistant. An end user has submitted the following ticket:

"{problem_summary}"

Please:
1. Suggest a one-paragraph fix that an engineer could apply
2. List the required skills as a JSON array (e.g., ["Outlook", "Azure AD", "Exchange Online"])
3. Explain briefly why each skill is needed
4. Suggest the top 3 most qualified engineers for this ticket based on the provided skills matrix

Respond like this:
Resolution: <one-paragraph fix>
Skills: ["Azure AD", "Outlook", "Exchange Online"]
SkillRationale:
  Azure AD: "Needed for login troubleshooting",
  Outlook: "Issue is with desktop Outlook client",
  Exchange Online: "Mailbox is cloud-hosted"
TopEngineers:
  - Jane Doe: "Expert in Outlook and Azure AD"
  - John Smith: "Strong Exchange Online experience"
  - F. Mulyadi: "Well-rounded across all required skills"
"""

    res = client.chat.completions.create(
        model=deployment,
        messages=[{"role": "user", "content": prompt}],
        temperature=0.2
    )
    response = res.choices[0].message.content

    resolution = next((line.replace("Resolution:", "").strip() for line in response.splitlines() if line.startswith("Resolution:")), "")
    skills_line = next((line for line in response.splitlines() if line.startswith("Skills:")), "[]")
    skills = json.loads(skills_line.replace("Skills:", "").strip())

    top_engineers = []
    if "TopEngineers:" in response:
        parsing = False
        for line in response.splitlines():
            if line.strip().startswith("TopEngineers:"):
                parsing = True
                continue
            if parsing and line.strip().startswith("- "):
                parts = line.strip()[2:].split(":", 1)
                if len(parts) == 2:
                    top_engineers.append({
                        "name": parts[0].strip(),
                        "explanation": parts[1].strip().strip('"')
                    })

    return skills, resolution, top_engineers

# Query engineers with high matching scores for the extracted skills
def get_top_engineers(skills):
    conn_str = os.getenv("SQL_CONNECTION_STRING")
    conn = pyodbc.connect(conn_str)
    cursor = conn.cursor()
    skill_list = ",".join(f"'{s}'" for s in skills)
    query = f"""
    SELECT TOP 3 e.EngineerName, SUM(sa.Score) AS MatchScore
    FROM Employees e
    JOIN SkillAssessments sa ON sa.Email = e.Email
    WHERE sa.SkillName IN ({skill_list}) AND sa.Score >= 3
    GROUP BY e.EngineerName
    ORDER BY MatchScore DESC;
    """
    logging.info(f"Executing SQL query: {query}")
    cursor.execute(query)
    rows = cursor.fetchall()
    logging.info(f"Query returned {len(rows)} rows")
    return [{
        "name": row.EngineerName,
        "score": row.MatchScore,
        "explanation": f"{row.EngineerName} scored {row.MatchScore} for the required skills: {', '.join(skills)}"
    } for row in rows]

# Azure Function main entry point
def main(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = req.get_json()
        problem = body.get("problem_summary", "")
        logging.info(f"SQL_CONNECTION_STRING: {os.getenv('SQL_CONNECTION_STRING')}")
        logging.info(f"AZURE_OPENAI_KEY: {os.getenv('AZURE_OPENAI_KEY')}")
        logging.info(f"AZURE_OPENAI_ENDPOINT: {os.getenv('AZURE_OPENAI_ENDPOINT')}")
        logging.info(f"AZURE_OPENAI_DEPLOYMENT: {os.getenv('AZURE_OPENAI_DEPLOYMENT')}")
        logging.info(f"AZURE_OPENAI_VERSION: {os.getenv('AZURE_OPENAI_VERSION')}")
        skills, resolution, top_engineers = extract_skills(problem)
        engineers = get_top_engineers(skills)
        logging.info(f"Top engineers from DB: {engineers}")

        return func.HttpResponse(
            json.dumps({
                "problem_summary": problem,
                "resolution": resolution,
                "skills_matched": skills,
                "recommended_engineers": engineers,
                "llm_recommended_engineers": top_engineers
            }),
            status_code=200,
            mimetype="application/json"
        )
    except Exception as e:
        logging.error(f"Error in triage function: {str(e)}")
        return func.HttpResponse(str(e), status_code=500)
