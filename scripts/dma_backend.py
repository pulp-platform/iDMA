# Copyright (c) 2020 ETH Zurich, University of Bologna
# All rights reserved.
#
# This code is under development and not yet released to the public.
# Until it is released, the code is under the copyright of ETH Zurich and
# the University of Bologna, and may contain confidential and/or unpublished
# work. Any reuse/redistribution is strictly forbidden without written
# permission from ETH Zurich.

# DMA backend model
# experimental code
# this could should not be used by anyone, 
# especially not in production environments

# split address in bus address and offset
def address_split (addr, data_width = 512):
    bytes_per_word = data_width // 8
    # bus-aligned address
    bus_addr = (addr // bytes_per_word) * bytes_per_word
    # word offset
    offset   = addr % bytes_per_word
    return [bus_addr, offset]


# number ob bytes until next page crossing
def bytes_to_page_crossing (addr, deburst, data_width = 512):
    if not deburst:
        # pages are 4kiB
        offset   = addr % 4096
        return 4096 - offset;
    else:
        bus_width = data_width // 8
        # pages are only the size of the bus to deburst
        offset   = addr % bus_width
        return bus_width - offset;


# combine read and write pages
def bytes_to_page_crossings (src, dst, deburst):
    src_bytes = bytes_to_page_crossing(src, deburst)
    dst_bytes = bytes_to_page_crossing(dst, deburst)
    cmb_bytes = min(src_bytes, dst_bytes)

    return [src_bytes, dst_bytes, cmb_bytes]


# number of bytes possible in current situation
def bytes_possible (src, dst, decouple, deburst, data_width = 512):
    bus_width = data_width // 8
    # how many bytes are possible in next burst?
    [src_bytes, dst_bytes, cmb_bytes] = bytes_to_page_crossings(src, dst, deburst)
    if not deburst: 
        if decouple:
            src_bytes = min(src_bytes, 4096)
            dst_bytes = min(dst_bytes, 4096)
        else:
            src_bytes = min(cmb_bytes, 4096)
            dst_bytes = src_bytes
        return [src_bytes, dst_bytes]
    else:
        if decouple:
            src_bytes = min(src_bytes, bus_width)
            dst_bytes = min(dst_bytes, bus_width)
        else:
            src_bytes = min(cmb_bytes, bus_width)
            dst_bytes = src_bytes
        return [src_bytes, dst_bytes]


# how many bytes are left in transfer
def bytes_left (src, dst, num_bytes_src, num_bytes_dst, decouple, deburst):
    [src_bp, dst_bp] = bytes_possible(src, dst, decouple, deburst)
    num_bytes_src = min(num_bytes_src , src_bp)
    num_bytes_dst = min(num_bytes_dst , dst_bp)

    return [num_bytes_src, num_bytes_dst]


# transform number bytes into number of beats
def bytes_to_beats (num_bytes, deburst, data_width = 512):
    bus_width = data_width // 8
    if not deburst:
        return min(num_bytes // bus_width, 4096 // bus_width, 256)
    else:
        return min(num_bytes // bus_width, 1, 256) 


# calculate transfer tailer
def calc_tailer (num_bytes, data_width = 512):
    bus_width = data_width // 8
    return (bus_width - (bus_width - num_bytes) % bus_width) % bus_width


# define necessary shift to realign data
def realign_shift (src, dst, data_width = 512):
    bus_width = data_width // 8
    src_offset = address_split(src)[1]
    dst_offset = address_split(dst)[1]
    return (dst_offset - src_offset) % bus_width


# create masks
def create_masks (offset, tailer, data_width = 512):
    full_mask = 2**(data_width // 8) - 1
    first_mask = (full_mask << offset) & full_mask
    if (tailer == 0):
        last_mask = full_mask
    else:
        last_mask = ~(full_mask << tailer) & full_mask
    single_mask = first_mask & last_mask
    return [first_mask, full_mask, last_mask, single_mask]


# barrel shifter
def barrel_shift (shift, mask, granularity = 1, data_width = 512):
    bus_width = data_width // 8
    shift = shift * granularity
    full_mask = 2**(data_width // 8) - 1
    res = (mask << shift) & full_mask
    res += (mask >> (bus_width - shift)) & full_mask
    return res


# split transfer in axi-conform read / write requests
def axi_read_writes(src, dst, num_bytes, decouple, deburst):

    read_requests  = []
    write_requests = []

    # split read and write pipeline
    num_bytes_src = num_bytes
    num_bytes_dst = num_bytes

    # calculaate the shift 
    shift = realign_shift(src, dst)

    while True:
        written = False
        # address splitting
        [src_bus_addr, src_offset] = address_split(src)
        [dst_bus_addr, dst_offset] = address_split(dst)
        # bytes left in page / burst
        [bytes_left_src, bytes_left_dst] = bytes_left(
                       src, dst, num_bytes_src, num_bytes_dst, decouple, deburst)

        # issue read requests
        if num_bytes_src:
            num_beats = bytes_to_beats(bytes_left_src + src_offset - 1, deburst)
            tailer = calc_tailer(bytes_left_src + src_offset)
            read_requests.append( {'addr': src_bus_addr, 'size': num_beats, 'offset': src_offset, 'tailer': tailer, 'shift': shift} )
            src += bytes_left_src
            num_bytes_src -= bytes_left_src
            written = True

        # issue read requests
        if num_bytes_dst:
            num_beats = bytes_to_beats(bytes_left_dst + dst_offset - 1, deburst)
            tailer = calc_tailer(bytes_left_dst + dst_offset)
            write_requests.append( {'addr': dst_bus_addr, 'size': num_beats, 'offset': dst_offset, 'tailer': tailer} )
            dst += bytes_left_dst
            num_bytes_dst -= bytes_left_dst
            written = True

        if not written:
            break

    return [read_requests, write_requests]


# return a list of reads
def data_path_read (read_requests):

    reads = []

    # iterate over the requests
    for read_request in read_requests:
        # calculate masks
        masks = create_masks(read_request['offset'], read_request['tailer'])

        # issue reads
        for b in range(0, read_request['size'] + 1):
            # single transfer
            if (read_request['size'] == 0):
                mask = masks[3]
            else:
                # first read
                if (b == 0):
                    mask = masks[0]
                # last transfer
                elif (b == read_request['size']):
                    mask = masks[2]
                else:
                    mask = masks[1]

            write_aligned_mask = barrel_shift(read_request['shift'], mask)
            # append masks to read
            reads.append( {'r_mask': mask, 'wa_mask': write_aligned_mask} )

    return reads


# return a list of writes
def data_path_write (write_requests):

    writes = []

    # iterate over the requests
    for write_request in write_requests:
        # calculate masks
        masks = create_masks(write_request['offset'], write_request['tailer'])

        # issue writes
        for b in range(0, write_request['size'] + 1):
            # single transfer
            if (write_request['size'] == 0):
                mask = masks[3]
            else:
                # first write
                if (b == 0):
                    mask = masks[0]
                # last transfer
                elif (b == write_request['size']):
                    mask = masks[2]
                else:
                    mask = masks[1]

            # append masks to writes
            writes.append( {'w_mask': mask } )

    return writes


# split a 1D request in AW/AR/R/W like transfers
def dma_backend (src, dst, num_bytes, decouple, deburst):

    [read_request, write_request] = axi_read_writes(src, dst, num_bytes, decouple, deburst)

    reads  = data_path_read(read_request)
    writes = data_path_write(write_request)

    return [read_request, write_request, reads, writes]

