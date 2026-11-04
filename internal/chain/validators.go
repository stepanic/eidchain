package chain

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
)

// Validators registered with an eID card (feature eid-validators).
//
// The card does not sign blocks: that needs a PIN for every signature and a
// person at the reader. It signs once, a record that names a key the node holds,
// and that key signs the blocks. The person is identified by the certificate's
// serialNumber, which on a national eID card is the personal ID number and stays
// the same when the card is replaced, so one person holds at most one key.
//
// A registered key is a candidate: it may sign blocks but does not count toward
// N, the number the signer window and the quorum are taken from. It is counted
// from the first block it signs. Without that, registering keys that no node runs
// would raise N until the running keys could not fill the signer window, and the
// chain would stop. For the same reason a counted key that has signed nothing for
// IdleBlocks becomes a candidate again; signing a block counts it once more.
//
// A key stops being a validator when its card's certificate expires. A revoked
// certificate is not noticed: that would need OCSP evidence in the chain.

const validatorDomain = "eidchain/validator/v1\n"

// Holder is the person who registered a validator key.
type Holder struct {
	Identity string // the certificate subject's serialNumber ("PNOHR-" + OIB); never shown
	Name     string // the certificate's common name, for display
	NotAfter int64  // the certificate's expiry, unix seconds: the key is dropped then
}

// Registration is a payload that makes a key a validator. Its eID signature says
// who; Proof, made with the key itself, shows the registrant holds that key, so
// nobody can enrol a key of someone else's.
type Registration struct {
	Type    string `json:"type"` // "validator"
	Chain   Hash   `json:"chain"`
	Key     string `json:"key"`   // base64 DER SPKI (ECDSA P-256)
	Proof   string `json:"proof"` // base64 ASN.1 ECDSA by Key over RegistrationHash
	Created string `json:"created,omitempty"`
}

// RegistrationHash is what the registered key signs: this chain and that key.
func RegistrationHash(chain Hash, key string) Hash {
	v := struct {
		Chain Hash   `json:"chain"`
		Key   string `json:"key"`
	}{chain, key}
	return sha256.Sum256(append([]byte(validatorDomain), canonical(v)...))
}

// NewRegistration returns the payload text that registers s on chain, for a
// person to sign with their eID card.
func NewRegistration(chain Hash, s Signer, created time.Time) (string, error) {
	key, err := EncodePublicKey(&s.Key.PublicKey)
	if err != nil {
		return "", err
	}
	h := RegistrationHash(chain, key)
	sig, err := ecdsa.SignASN1(rand.Reader, s.Key, h[:])
	if err != nil {
		return "", err
	}
	r := Registration{Type: "validator", Chain: chain, Key: key, Proof: base64.StdEncoding.EncodeToString(sig), Created: created.UTC().Format(time.RFC3339)}
	return string(canonical(r)), nil
}

// ParseRegistration returns the registration in a payload; ok is false if the
// payload is some other record.
func ParseRegistration(payload string) (r Registration, ok bool, err error) {
	var head struct {
		Type string `json:"type"`
	}
	if json.Unmarshal([]byte(payload), &head) != nil || head.Type != "validator" {
		return r, false, nil
	}
	if err := json.Unmarshal([]byte(payload), &r); err != nil {
		return r, true, fmt.Errorf("validator registration: %w", err)
	}
	return r, true, nil
}

// holderOf identifies the person a certificate was issued to. Only a natural
// person's ID number ("PNO", ETSI EN 319 412-1) qualifies: it is what limits a
// person to one key.
func holderOf(c *x509.Certificate) (Holder, error) {
	sn := c.Subject.SerialNumber
	if !strings.HasPrefix(sn, "PNO") {
		return Holder{}, errors.New("the certificate does not carry a personal ID number, so it cannot register a validator")
	}
	return Holder{Identity: sn, Name: SubjectName(c), NotAfter: c.NotAfter.Unix()}, nil
}

// keyOf returns the key held by a person, if any.
func (s *State) keyOf(identity string) string {
	for id, h := range s.Holders {
		if h.Identity == identity {
			return id
		}
	}
	return ""
}

// ApplyRegistration returns the state after e, a payload of a block at height
// signed by cert, if e is a validator registration and the feature is active.
// Any other payload leaves working as it is. Registering replaces the key the
// person held before, in its place, so a new card or a new server keeps standing.
func (p *Params) ApplyRegistration(working *State, e PayloadEntry, cert *x509.Certificate, height uint64, at time.Time) (*State, error) {
	if !p.Features.Active(FeatureEIDValidators, height) {
		return working, nil
	}
	r, ok, err := ParseRegistration(e.Payload)
	if !ok || err != nil {
		return working, err
	}
	if r.Chain != p.GenesisHash {
		return nil, errors.New("validator registration is for a different chain")
	}
	pub, err := DecodePublicKey(r.Key)
	if err != nil {
		return nil, fmt.Errorf("validator registration: key: %w", err)
	}
	sig, err := decodeB64(r.Proof)
	h := RegistrationHash(r.Chain, r.Key)
	if err != nil || !ecdsa.VerifyASN1(pub, h[:], sig) {
		return nil, errors.New("validator registration: the proof is not the key's signature")
	}
	holder, err := holderOf(cert)
	if err != nil {
		return nil, err
	}
	if at.Unix() >= holder.NotAfter {
		return nil, errors.New("validator registration: the certificate has expired")
	}
	id, _ := KeyID(pub)
	if working.Has(id) {
		return nil, errors.New("validator registration: the key is already a validator")
	}
	c := working.clone()
	if old := c.keyOf(holder.Identity); old != "" {
		c.swap(old, id, pub)
	} else {
		c.Candidates = append(c.Candidates, id)
		c.Keys[id] = pub
		c.LastSigned[id] = height
	}
	c.Holders[id] = holder
	return c, nil
}

// IdleBlocks is how many blocks a counted key may go without signing before it
// stops being counted. Blocks are only made when there is something to put in
// them and the first node to cut one wins, so a running key can miss many turns;
// this leaves it several.
func IdleBlocks(st *State) uint64 { return uint64(max(16, 4*len(st.IDs))) }

// settle applies what follows from a block at height, signed by signer at time
// t, once its payloads and rotations are in st: the signer is counted, expired
// keys go, and keys idle for too long stop being counted.
func (p *Params) settle(st *State, signer string, height uint64, t int64) *State {
	c := st.clone()
	if c.Has(signer) { // a rotation or registration in the block may have replaced it
		c.LastSigned[signer] = height
		if !c.Active(signer) {
			c.Candidates = slices.DeleteFunc(c.Candidates, func(x string) bool { return x == signer })
			c.IDs = append(c.IDs, signer)
		}
	}
	for id := range c.Holders {
		if c.Expired(id, t) {
			c.drop(id)
		}
	}
	idle := IdleBlocks(c)
	for _, id := range slices.Clone(c.IDs) {
		last, ok := c.LastSigned[id]
		switch {
		case !ok: // counted before the feature or added by a rotation: the clock starts now
			c.LastSigned[id] = height
		case id != signer && height-last >= idle:
			c.IDs = slices.DeleteFunc(c.IDs, func(x string) bool { return x == id })
			c.Candidates = append(c.Candidates, id)
		}
	}
	return c
}
