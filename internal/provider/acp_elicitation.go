package provider

import (
	"context"
	"encoding/json"
	"time"

	"agent-acp.local/sdks/go/runtime"
)

func configureACPElicitation(j job, config *runtime.Config, a *api, s *screen) {
	if !j.ACPElicitation || j.SSH != nil || j.BuiltinInstance != "" {
		return
	}
	path := "/v1/workers/" + j.Worker.ID + "/elicitations"
	config.Elicitation = &runtime.Elicitation{
		Form: true, URL: true,
		Create: func(ctx context.Context, request runtime.ElicitationRequest) (runtime.ElicitationResponse, error) {
			s.line("The provider requested input. List pending interactions at " + path + ".")
			raw, err := a.client.AwaitElicitation(ctx, path+"/await", request)
			if err != nil {
				return runtime.ElicitationResponse{}, err
			}
			var response runtime.ElicitationResponse
			err = json.Unmarshal(raw, &response)
			return response, err
		},
		Complete: func(ctx context.Context, request runtime.ElicitationRequest) {
			go func() {
				ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
				defer cancel()
				_ = a.requestContext(ctx, "POST", path+"/complete", map[string]string{
					"sessionId":     request.SessionID,
					"elicitationId": request.ElicitationID,
				}, nil)
			}()
		},
	}
}
