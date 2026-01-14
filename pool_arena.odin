package huuru

import "core:mem"

Free_Node :: struct {
    next: ^Free_Node
}

Pool_Arena :: struct {
    data: []byte,
    chunk_size: int,
    head: ^Free_Node,
}

pool_init :: proc(p: ^Pool_Arena, data: []byte, chunk_size: int) {
	assert(chunk_size >= size_of(Free_Node), "Chunk size is too small");
	assert(len(data) >= chunk_size, "Backing buffer length is smaller than the chunk size");

    p.data = data
    p.chunk_size = chunk_size

    pool_free_all(p)
}

pool_free_all :: proc(p: ^Pool_Arena) {
    chunk_count := len(p.data) / p.chunk_size
    
    for i in 0..<chunk_count {
        ptr := &p.data[i * p.chunk_size]
        node := cast(^Free_Node)ptr
        node.next = p.head
        p.head = node
    }
}

pool_alloc :: proc(p: ^Pool_Arena) -> rawptr {
    node := p.head

    if node == nil {
        assert(false, "Pool has no free memory left")
    }

    p.head = p.head.next

    return mem.set(node, 0, p.chunk_size)
}

pool_free :: proc(p: ^Pool_Arena, ptr: rawptr) {
    node: ^Free_Node

    start := uintptr(p.data[0])
    end := uintptr(p.data[len(p.data)])

    if ptr == nil {
        assert(false, "Trying to free a nil pointer")
    }

    if !(start <= uintptr(ptr) && uintptr(ptr) < end) {
        assert(false, "Memory is out of bounds for the buffer")
    }

    node = cast(^Free_Node)ptr
    node.next = p.head
    p.head = node
}