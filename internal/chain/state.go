package chain

import (
	"crypto/ecdsa"
	"errors"
	"fmt"
	"slices"
)

// State is the authority set in force after a given block. Rotations change
// it, so every block is validated against the state of its parent: a key is
// "valid at the time" if it is in the parent's state.
type State struct {
	IDs  []string // key IDs, in slot order (a replacement keeps the old key's slot)
	Keys map[string]*ecdsa.PublicKey
	Seq  uint64 // rotations applied so far on this branch
}

// Has reports whether id is an authority in this state.
func (s *State) Has(id string) bool { _, ok := s.Keys[id]; return ok }

func (s *State) clone() *State {
	c := &State{IDs: append([]string(nil), s.IDs...), Keys: make(map[string]*ecdsa.PublicKey, len(s.Keys)), Seq: s.Seq}
	for k, v := range s.Keys {
		c.Keys[k] = v
	}
	return c
}

// SignerWindow is how many preceding blocks a signer must not appear in (Clique
// rule): a key may sign at most one block in any floor(N/2)+1 consecutive blocks,
// so rewriting history takes a majority of the keys. N is the number of keys in
// this state, so the window follows additions and removals.
func (s *State) SignerWindow() int { return len(s.IDs) / 2 }

// replace returns a copy of s with oldID's slot given to the new key.
func (s *State) replace(oldID, newID string, pub *ecdsa.PublicKey) *State {
	c := s.clone()
	for i, id := range c.IDs {
		if id == oldID {
			c.IDs[i] = newID
		}
	}
	delete(c.Keys, oldID)
	c.Keys[newID] = pub
	c.Seq++
	return c
}

// add returns a copy of s with the new key in a new, last slot.
func (s *State) add(newID string, pub *ecdsa.PublicKey) *State {
	c := s.clone()
	c.IDs = append(c.IDs, newID)
	c.Keys[newID] = pub
	c.Seq++
	return c
}

// remove returns a copy of s without oldID.
func (s *State) remove(oldID string) *State {
	c := s.clone()
	c.IDs = slices.DeleteFunc(c.IDs, func(id string) bool { return id == oldID })
	delete(c.Keys, oldID)
	c.Seq++
	return c
}

// Quorum is how many approvals a rotation in the block at height needs from the
// keys of st, the state of that block's parent. With the authority-changes
// feature it is a majority of st: a fixed number from the genesis would let a
// minority rule once keys are added, or block every change once enough are removed.
func (p *Params) Quorum(st *State, height uint64) int {
	if p.Features.Active(FeatureAuthorityChanges, height) {
		return len(st.IDs)/2 + 1
	}
	return p.Rules.RotationQuorum
}

// CheckChange reports whether c, ignoring its approvals, can apply to working
// in the block at height. It returns the new key, if the change has one.
func (p *Params) CheckChange(working *State, c KeyChange, height uint64) (*ecdsa.PublicKey, string, error) {
	switch c.Type {
	case "replace":
	case "add", "remove":
		if !p.Features.Active(FeatureAuthorityChanges, height) {
			return nil, "", fmt.Errorf("rotation type %q needs the %s feature", c.Type, FeatureAuthorityChanges)
		}
	default:
		return nil, "", fmt.Errorf("unknown rotation type %q", c.Type)
	}
	if c.Chain != p.GenesisHash {
		return nil, "", errors.New("rotation is for a different chain")
	}
	if c.Seq != working.Seq {
		return nil, "", fmt.Errorf("rotation seq %d, expected %d", c.Seq, working.Seq)
	}
	if c.Type == "add" {
		if c.Old != "" {
			return nil, "", errors.New("an add rotation must not name an old key")
		}
	} else if !working.Has(c.Old) {
		return nil, "", fmt.Errorf("rotation %ss a key that is not an authority", c.Type)
	}
	if c.Type == "remove" {
		if c.NewKey != "" {
			return nil, "", errors.New("a remove rotation must not carry a new key")
		}
		// Without a key nobody can sign a block or approve another rotation,
		// so the chain would stop for good.
		if len(working.IDs) == 1 {
			return nil, "", errors.New("the last authority cannot be removed")
		}
		return nil, "", nil
	}
	pub, err := DecodePublicKey(c.NewKey)
	if err != nil {
		return nil, "", fmt.Errorf("new key: %w", err)
	}
	newID, _ := KeyID(pub)
	if working.Has(newID) {
		return nil, "", errors.New("new key is already an authority")
	}
	return pub, newID, nil
}

// ApplyRotation checks r and returns the state after it. signers is the state
// whose keys may approve (the parent's state); working is the state the change
// applies to (it differs from signers only after earlier rotations in the same
// block). height is the height of the block that carries r.
func (p *Params) ApplyRotation(signers, working *State, r Rotation, height uint64) (*State, error) {
	c := r.Change
	pub, newID, err := p.CheckChange(working, c, height)
	if err != nil {
		return nil, err
	}
	if err := p.checkApprovals(signers, r, p.Quorum(signers, height)); err != nil {
		return nil, err
	}
	switch c.Type {
	case "add":
		return working.add(newID, pub), nil
	case "remove":
		return working.remove(c.Old), nil
	}
	return working.replace(c.Old, newID, pub), nil
}

// checkApprovals demands at least quorum distinct, valid signatures from keys
// that are authorities in signers.
func (p *Params) checkApprovals(signers *State, r Rotation, quorum int) error {
	h := r.Change.Hash()
	prev := ""
	for i, s := range r.Signatures {
		if i > 0 && s.Signer <= prev {
			return errors.New("rotation signatures must be sorted by signer and distinct")
		}
		prev = s.Signer
		pub, ok := signers.Keys[s.Signer]
		if !ok {
			return fmt.Errorf("rotation signed by %s…, which is not a currently valid authority", short(s.Signer))
		}
		sig, err := decodeB64(s.Signature)
		if err != nil || !ecdsa.VerifyASN1(pub, h[:], sig) {
			return fmt.Errorf("invalid rotation signature from %s…", short(s.Signer))
		}
	}
	if len(r.Signatures) < quorum {
		return fmt.Errorf("rotation has %d approvals, %d required", len(r.Signatures), quorum)
	}
	return nil
}

func short(id string) string {
	if len(id) > 12 {
		return id[:12]
	}
	return id
}
