URL=$(gcloud run services describe query --region=asia-south1 --format='value(status.url)')
TOKEN=$(gcloud auth print-identity-token)

curl -sS -X POST "$URL/query" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"question\":\"$1\"}" \
    | python3 -m json.tool

