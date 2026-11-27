package service

import (
	"context"
	"os"

	"agentcommander/internal/worktrees"
)

type launchCheckKey struct{}

type launchPrerequisites struct {
	client, path, host, kind string
	agent                    bool
}

type launchPreparation struct {
	input                launchPrerequisites
	id, checkout, branch string
	source, isolated     *worktrees.Checkout
	err                  error
	legacy               *legacySessionProof
	legacySpec           LaunchSpec
}

type launchCheck struct {
	prepare func(context.Context) launchPreparation
}

func (*launchCheck) Error() string { return "launch prerequisites need verification" }

func (s *service) prepareLaunch(ctx context.Context, input launchPrerequisites) (launchPreparation, error) {
	if prepared, ok := ctx.Value(launchCheckKey{}).(launchPreparation); ok {
		if prepared.input != input {
			return launchPreparation{}, conflict("launch changed during verification")
		}
		return prepared, prepared.err
	}
	return launchPreparation{}, &launchCheck{prepare: func(ctx context.Context) launchPreparation {
		prepared := launchPreparation{input: input, id: randomID("w-"), checkout: input.path}
		prepared.err = s.checkLaunch(ctx, &prepared)
		return prepared
	}}
}

func (s *service) checkLaunch(ctx context.Context, prepared *launchPreparation) error {
	input := prepared.input
	if input.host == "" {
		if info, err := os.Stat(input.path); err != nil || !info.IsDir() {
			return bad("project path must be an existing directory")
		}
	}
	if input.host == "" || input.host == "localhost" {
		if input.agent {
			if launcher, ok := s.launcher.(interface{ CheckAgentClient(string) error }); ok {
				if err := launcher.CheckAgentClient(input.client); err != nil {
					return conflict(err.Error())
				}
			}
		}
		if launcher, ok := s.launcher.(interface{ CheckClient(string) error }); ok {
			if err := launcher.CheckClient(input.client); err != nil {
				return conflict(err.Error())
			}
		}
	} else {
		placement, ok := s.launcher.(hostPlacement)
		if !ok {
			return conflict("SSH hosts are unavailable")
		}
		checkout, err := placement.WorkerCheckout(input.host, input.path, input.client)
		if err != nil {
			return conflict(err.Error())
		}
		prepared.checkout = checkout
	}
	if input.host == "" {
		prepared.branch = checkoutBranch(ctx, input.path)
	}
	if input.kind != "coding" {
		return nil
	}
	if input.host != "localhost" {
		return conflict("coding worktree placement currently requires the coordinator's host")
	}
	if checker, ok := s.launcher.(interface{ CheckCodingClient(string) error }); ok {
		if err := checker.CheckCodingClient(input.client); err != nil {
			return conflict(err.Error())
		}
	}
	base, err := worktrees.Source(ctx, input.path)
	if err != nil {
		return conflict(err.Error())
	}
	git, err := worktrees.New()
	if err != nil {
		return err
	}
	placement, err := git.Plan(ctx, base, prepared.id)
	if err != nil {
		return conflict(err.Error())
	}
	prepared.source, prepared.isolated, prepared.checkout = &base, &placement, placement.Path
	return nil
}
