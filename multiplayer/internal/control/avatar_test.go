package control

import (
	"bytes"
	"encoding/base64"
	"image"
	"image/jpeg"
	"testing"
)

func TestDecodeJPEGAvatar(t *testing.T) {
	var jpg bytes.Buffer
	if err := jpeg.Encode(&jpg, image.NewRGBA(image.Rect(0, 0, 1, 1)), nil); err != nil {
		t.Fatal(err)
	}
	encoded := base64.StdEncoding.EncodeToString(jpg.Bytes())
	mime, data, err := decodeAvatar("data:image/jpeg;base64," + encoded)
	if err != nil || mime != "image/jpeg" || !bytes.Equal(data, jpg.Bytes()) {
		t.Fatalf("JPEG round trip: content type %q, error %v", mime, err)
	}
	for _, url := range []string{
		"data:image/png;base64," + encoded,
		"data:image/svg+xml;base64," + encoded,
		"data:image/jpeg;base64," + encoded + "!",
	} {
		if _, _, err := decodeAvatar(url); err == nil {
			t.Fatal("accepted invalid avatar type or encoding")
		}
	}
}
