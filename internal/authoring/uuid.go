package authoring

import (
	"crypto/sha1"
	"fmt"
	"strings"
)

// namespace is Gopherwood's own namespace for the name-based uuids of authored courses,
// chapters and lessons. It never changes: a lesson's uuid depends only on its slugs.
var namespace = mustUUID("6e88cbe1-97a8-4208-96e2-aa1be702c753")

// CourseUUID, ChapterUUID and LessonUUID are the uuids of authored content: version 5 uuids
// in Gopherwood's namespace, named by the slugs from the course down, joined with /.
func CourseUUID(course string) string { return uuidV5(namespace, course) }

func ChapterUUID(course, chapter string) string { return uuidV5(namespace, course+"/"+chapter) }

func LessonUUID(course, chapter, lesson string) string {
	return uuidV5(namespace, course+"/"+chapter+"/"+lesson)
}

// uuidV5 is the RFC 4122 name-based uuid, from SHA-1, of name in a namespace.
func uuidV5(ns [16]byte, name string) string {
	h := sha1.New()
	h.Write(ns[:])
	h.Write([]byte(name))
	var u [16]byte
	copy(u[:], h.Sum(nil))
	u[6] = u[6]&0x0f | 0x50 // version 5
	u[8] = u[8]&0x3f | 0x80 // the RFC 4122 variant
	return fmt.Sprintf("%x-%x-%x-%x-%x", u[0:4], u[4:6], u[6:8], u[8:10], u[10:16])
}

func mustUUID(s string) [16]byte {
	var u [16]byte
	hex := strings.ReplaceAll(s, "-", "")
	if len(hex) != 32 {
		panic("authoring: bad uuid " + s)
	}
	for i := range u {
		if _, err := fmt.Sscanf(hex[2*i:2*i+2], "%02x", &u[i]); err != nil {
			panic("authoring: bad uuid " + s)
		}
	}
	return u
}
