package control

import (
	"bytes"
	"encoding/base64"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"strings"
)

func decodeAvatar(url string) (string, []byte, error) {
	if url == "" {
		return "", nil, nil
	}
	if len(url) > 64<<10 {
		return "", nil, bad("avatar data URL exceeds 64 KiB")
	}
	header, encoded, _ := strings.Cut(url, ",")
	if header != "data:image/png;base64" && header != "data:image/jpeg;base64" {
		return "", nil, bad("expected a PNG or JPEG data URL")
	}
	data, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil {
		return "", nil, bad("invalid base64 avatar")
	}
	// Inspect the image header without allocating its full pixel buffer.
	_, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || header != "data:image/"+format+";base64" {
		return "", nil, bad("avatar does not match its image type")
	}
	return "image/" + format, data, nil
}
