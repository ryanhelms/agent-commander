module agentcommander

go 1.25.0

require (
	agent-acp.local/sdks/go v0.1.16
	github.com/coder/acp-go-sdk v0.20.0
	github.com/google/jsonschema-go v0.4.3
	github.com/modelcontextprotocol/go-sdk v1.8.0
	github.com/segmentio/encoding v0.5.4
	google.golang.org/protobuf v1.36.12
)

require (
	agent-acp.local/transport v0.1.1 // indirect
	github.com/segmentio/asm v1.1.3 // indirect
	github.com/yosida95/uritemplate/v3 v3.0.2 // indirect
	golang.org/x/oauth2 v0.35.0 // indirect
	golang.org/x/sync v0.20.0 // indirect
	golang.org/x/sys v0.41.0 // indirect
	golang.org/x/time v0.15.0 // indirect
)

replace agent-acp.local/sdks/go => ../agent-acp/sdks/go

replace agent-acp.local/transport => ../agent-acp-transport
