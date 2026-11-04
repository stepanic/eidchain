package chain_test

import (
	"crypto/x509/pkix"
	"encoding/base64"
	"slices"
	"strings"
	"testing"
	"time"

	"eidchain/internal/chain"
)

func validatorEnv(t *testing.T) *env {
	t.Helper()
	e := newEnv(t, 3)
	var err error
	e.store, err = chain.Open(e.dir, e.genesis.Hash(), chain.Options{Features: chain.Schedule{
		chain.FeatureAuthorityChanges: chain.At(1), chain.FeatureEIDValidators: chain.At(2)}})
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func newSigner(t *testing.T) chain.Signer {
	t.Helper()
	k, err := chain.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	id, _ := chain.KeyID(&k.PublicKey)
	return chain.Signer{ID: id, Key: k}
}

// register is a registration of key, signed with card.
func (e *env) register(card leaf, key chain.Signer) chain.PayloadEntry {
	e.t.Helper()
	return e.registration(card, &key, "")
}

func (e *env) registration(card leaf, key *chain.Signer, retire string) chain.PayloadEntry {
	e.t.Helper()
	text, err := chain.NewRegistration(e.genesis.Hash(), key, retire, time.Now())
	if err != nil {
		e.t.Fatal(err)
	}
	return chain.PayloadEntry{Payload: text, Signature: base64.StdEncoding.EncodeToString(cadesSign(e.t, card, []byte(text)))}
}

// at builds a signed block on the head with the given version and time.
func (e *env) at(t time.Time, s chain.Signer, payloads ...chain.PayloadEntry) *chain.Block {
	head, h := e.store.Head()
	b := &chain.Block{Header: chain.Header{Version: e.store.P.Features.VersionAt(h + 1), Height: h + 1, Prev: head, Time: t.Unix()}, Payloads: payloads}
	if err := chain.SignBlock(s, b); err != nil {
		e.t.Fatal(err)
	}
	return b
}

func (e *env) add(b *chain.Block) {
	e.t.Helper()
	if _, err := e.store.AddBlock(b); err != nil {
		e.t.Fatalf("block %d: %v", b.Header.Height, err)
	}
}

func (e *env) refused(b *chain.Block, want string) {
	e.t.Helper()
	if _, err := e.store.AddBlock(b); err == nil || !strings.Contains(err.Error(), want) {
		e.t.Fatalf("block %d: got %v, want an error containing %q", b.Header.Height, err, want)
	}
}

func person(e *env, oib string) leaf {
	return e.pki.LeafSubject(e.t, pkix.Name{CommonName: "OSOBA " + oib, SerialNumber: "PNOHR-" + oib})
}

func TestValidatorRegistration(t *testing.T) {
	e := validatorEnv(t)
	s := e.signers
	now := time.Now()
	pero, ana := person(e, "11111111111"), person(e, "22222222222")
	a, b := newSigner(t), newSigner(t)

	// Before the feature a registration is just a record.
	e.add(e.at(now, s[0], e.register(pero, a)))
	if e.store.HeadState().Has(a.ID) {
		t.Fatal("registered before the feature")
	}

	// Refused registrations make the block invalid.
	company := e.pki.LeafSubject(t, pkix.Name{CommonName: "FIRMA D.O.O.", SerialNumber: "VATHR-12345678901"})
	e.refused(e.at(now, s[1], e.register(company, a)), "personal ID number")
	forged := e.register(pero, a)
	forged.Payload = strings.Replace(forged.Payload, `"key":"`, `"key":"`+mustPub(t, b)+`","x":"`, 1)
	forged.Signature = base64.StdEncoding.EncodeToString(cadesSign(t, pero, []byte(forged.Payload)))
	e.refused(e.at(now, s[1], forged), "proof")
	e.refused(e.at(now, s[1], e.register(pero, s[2])), "already a validator")

	// A registered key is a candidate: it may sign, but N stays 3.
	e.add(e.at(now, s[1], e.register(pero, a)))
	st := e.store.HeadState()
	if !st.Has(a.ID) || st.Active(a.ID) || len(st.IDs) != 3 || st.SignerWindow() != 1 {
		t.Fatalf("after registering: IDs %d, candidates %v", len(st.IDs), st.Candidates)
	}
	e.refused(e.at(now, s[2], e.register(ana, a)), "already a validator")

	// Signing a block makes it count.
	e.add(e.at(now, a, e.payload("from a")))
	if st = e.store.HeadState(); !st.Active(a.ID) || len(st.IDs) != 4 || st.SignerWindow() != 2 {
		t.Fatalf("after signing: IDs %v, candidates %v", st.IDs, st.Candidates)
	}

	// The same person may run a second node with its own key. Both keys are one
	// voter: b may not sign while a's block is within the window,
	e.add(e.at(now, s[2], e.register(pero, b)))
	e.refused(e.at(now, b, e.payload("pero again")), "same person")
	e.add(e.at(now, s[0], e.payload("between")))
	// but may once it is out of it. Then both count, as one.
	e.add(e.at(now, b, e.payload("from b")))
	st = e.store.HeadState()
	if !st.Active(a.ID) || !st.Active(b.ID) || len(st.IDs) != 5 || st.Voters() != 4 || st.SignerWindow() != 2 {
		t.Fatalf("two keys of one person: IDs %d, voters %d", len(st.IDs), st.Voters())
	}
	// Approvals from both keys count once.
	rot := approved(t, chain.KeyChange{Type: "remove", Chain: e.genesis.Hash(), Seq: 0, Old: s[2].ID}, a, b, s[0])
	if n, q := st.Approvals(rot), e.store.P.Quorum(st, 10); n != 2 || q != 3 {
		t.Fatalf("approvals %d, quorum %d", n, q)
	}

	// A person retires only their own keys.
	e.refused(e.at(now, s[1], e.registration(ana, nil, a.ID)), "not one of yours")
	e.add(e.at(now, s[1], e.registration(pero, nil, a.ID)))
	if st = e.store.HeadState(); st.Has(a.ID) || !st.Active(b.ID) || st.Voters() != 4 {
		t.Fatalf("after retiring: IDs %v", st.IDs)
	}
	e.refused(e.at(now, a, e.payload("retired")), "not a currently valid authority")

	// Registering a key again with a new card renews it.
	newCard := e.pki.LeafUntil(t, pkix.Name{CommonName: "OSOBA 11111111111", SerialNumber: "PNOHR-11111111111"}, now.Add(72*time.Hour))
	e.add(e.at(now, s[2], e.register(newCard, b)))
	if st = e.store.HeadState(); st.Holders[b.ID].NotAfter != newCard.Cert.NotAfter.Unix() || !st.Active(b.ID) {
		t.Fatalf("not renewed: %+v", st.Holders[b.ID])
	}

	// A counted key that stops signing stops being counted.
	for i := range chain.IdleBlocks(st) {
		e.add(e.at(now, s[int(i)%3], e.payload("filler "+string(rune('a'+i%26))+string(rune('a'+i/26)))))
	}
	if st = e.store.HeadState(); st.Active(b.ID) || !slices.Contains(st.Candidates, b.ID) || len(st.IDs) != 3 || st.Voters() != 3 {
		t.Fatalf("after idling: IDs %v, candidates %v", st.IDs, st.Candidates)
	}
	// and counts again once it signs.
	e.add(e.at(now, b, e.payload("back")))
	if !e.store.HeadState().Active(b.ID) {
		t.Fatal("not counted again after signing")
	}
	if _, err := e.store.Verify(); err != nil {
		t.Fatal(err)
	}
}

func TestValidatorCertificateExpiry(t *testing.T) {
	e := validatorEnv(t)
	s := e.signers
	now := time.Now()
	e.add(e.at(now, s[0], e.payload("one")))
	short := e.pki.LeafUntil(t, pkix.Name{CommonName: "KRATKO", SerialNumber: "PNOHR-33333333333"}, now.Add(2*time.Minute))
	c := newSigner(t)
	e.add(e.at(now, s[1], e.register(short, c)))
	if !e.store.HeadState().Has(c.ID) {
		t.Fatal("not registered")
	}
	later := now.Add(3 * time.Minute)
	e.refused(e.at(later, c, e.payload("too late")), "expired")
	e.add(e.at(later, s[2], e.payload("after expiry")))
	if e.store.HeadState().Has(c.ID) {
		t.Fatal("an expired holder's key is still a validator")
	}
}
