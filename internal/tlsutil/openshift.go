// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package tlsutil

import (
	"context"
	"crypto/tls"
	"fmt"

	"github.com/go-logr/logr"
	configv1 "github.com/openshift/api/config/v1"
	openshifttls "github.com/openshift/controller-runtime-common/pkg/tls"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// OpenShiftTLSState bundles the TLS profile and adherence policy fetched from
// the OpenShift APIServer CR at startup.
type OpenShiftTLSState struct {
	TLSOpt          func(*tls.Config)
	ProfileSpec     configv1.TLSProfileSpec
	AdherencePolicy configv1.TLSAdherencePolicy
}

// FetchOpenShiftTLSProfile reads the cluster-wide TLS security profile and
// adherence policy from the OpenShift APIServer CR
// (apiserver.config.openshift.io/cluster). On non-OpenShift clusters the CRD
// does not exist and this returns an error, which callers treat as a no-op
// fallback to Go defaults.
func FetchOpenShiftTLSProfile(ctx context.Context, cfg *rest.Config, log logr.Logger) (*OpenShiftTLSState, error) {
	s := runtime.NewScheme()
	if err := configv1.Install(s); err != nil {
		return nil, err
	}

	cl, err := client.New(cfg, client.Options{Scheme: s})
	if err != nil {
		return nil, err
	}

	return fetchOpenShiftTLSProfile(ctx, cl, log)
}

// fetchOpenShiftTLSProfile is the client-injectable half of
// FetchOpenShiftTLSProfile, kept separate so it can be exercised with a fake
// client in unit tests.
func fetchOpenShiftTLSProfile(ctx context.Context, cl client.Client, log logr.Logger) (*OpenShiftTLSState, error) {
	apiServer := &configv1.APIServer{}
	if err := cl.Get(ctx, client.ObjectKey{Name: openshifttls.APIServerName}, apiServer); err != nil {
		return nil, fmt.Errorf("get APIServer: %w", err)
	}

	profileSpec, err := openshifttls.GetTLSProfileSpec(apiServer.Spec.TLSSecurityProfile)
	if err != nil {
		return nil, fmt.Errorf("get TLS profile: %w", err)
	}

	tlsOpt, unsupported := openshifttls.NewTLSConfigFromProfile(profileSpec)
	if len(unsupported) > 0 {
		log.Info("unsupported cipher suites in cluster TLS profile (skipped)", "ciphers", unsupported)
	}

	return &OpenShiftTLSState{
		TLSOpt:          tlsOpt,
		ProfileSpec:     profileSpec,
		AdherencePolicy: apiServer.Spec.TLSAdherence,
	}, nil
}
