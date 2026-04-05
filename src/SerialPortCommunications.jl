module SerialPortCommunications

# =========================
# Low-level constants / enums
# =========================

const libserialport = "libserialport"

@enum Parity::Cint begin
    PARITY_NONE = 0
    PARITY_ODD
    PARITY_EVEN
end

@enum StopBits::Cint begin
    STOPBITS_1 = 1
    STOPBITS_2 = 2
end

@enum FlowControl::Cint begin
    FLOW_NONE = 0
    FLOW_RTSCTS
    FLOW_XONXOFF
end

# =========================
# High-level configuration
# =========================

struct PortConfig
    baudrate::Int
    parity::Parity
    databits::Int
    stopbits::StopBits
    flowcontrol::FlowControl
end

PortConfig(; baudrate::Integer=9600,
            parity::Parity=PARITY_NONE,
            databits::Integer=8,
            stopbits::StopBits=STOPBITS_1,
            flowcontrol::FlowControl=FLOW_NONE) =
    PortConfig(baudrate, parity, databits, stopbits, flowcontrol)

# =========================
# Error types
# =========================

struct SerialError <: Exception
    code::Int
    context::Symbol
end

Base.showerror(io::IO, e::SerialError) =
    print(io, "SerialError in ", e.context, ": libserialport returned error code ", e.code)

struct PartialReadError <: Exception
    elements_read::Int
    partial_bytes::Int
end

Base.showerror(io::IO, e::PartialReadError) =
    print(io,
          "PartialReadError: read ",
          e.elements_read, " full elements and ",
          e.partial_bytes, " leftover bytes")

# =========================
# Internal state + metadata
# =========================

mutable struct SerialPortState
    handle::Ptr{Cvoid}
    config::PortConfig
end

struct SerialPortInfo
    name::String
    description::String
    transport::Symbol
end

struct SerialPort
    state::SerialPortState
    info::SerialPortInfo

    # Constructor 1: open with OS defaults
    function SerialPort(name::AbstractString)
        handle = get_port_handle(name)
        open_handle!(handle)
        info = get_port_info(handle)
        cfg  = get_config_from_os(handle)

        state = SerialPortState(handle, cfg)
        port  = new(state, info)
        finalizer(close, port)
        return port
    end

    # Constructor 2: open with explicit configuration
    function SerialPort(name::AbstractString, cfg::PortConfig)
        handle = get_port_handle(name)
        open_handle!(handle)
        info = get_port_info(handle)
        apply_config_to_os!(handle, cfg)

        state = SerialPortState(handle, cfg)
        port  = new(state, info)
        finalizer(close, port)
        return port
    end
end

# =========================
# Internal helpers
# =========================

function get_port_handle(name::AbstractString)
    port_ref = Ref{Ptr{Cvoid}}(C_NULL)

    err = ccall((:sp_get_port_by_name, libserialport), Cint,
                (Cstring, Ref{Ptr{Cvoid}}),
                name, port_ref)

    err < 0 && throw(SerialError(err, :get_port_handle))
    return port_ref[]
end

function open_handle!(handle::Ptr{Cvoid})
    err = ccall((:sp_open, libserialport), Cint,
                (Ptr{Cvoid}, Cint),
                handle, 3)  # SP_MODE_READ_WRITE

    err < 0 && throw(SerialError(err, :open_handle))
    return nothing
end

function get_port_info(handle::Ptr{Cvoid})
    name = unsafe_string(ccall((:sp_get_port_name, libserialport),
                               Cstring, (Ptr{Cvoid},), handle))

    desc_ptr = ccall((:sp_get_port_description, libserialport),
                     Cstring, (Ptr{Cvoid},), handle)
    description = desc_ptr == C_NULL ? "" : unsafe_string(desc_ptr)

    transport_code = ccall((:sp_get_port_transport, libserialport),
                           Cint, (Ptr{Cvoid},), handle)

    transport = transport_code == 0 ? :native :
                transport_code == 1 ? :usb :
                transport_code == 2 ? :bluetooth :
                :unknown

    return SerialPortInfo(name, description, transport)
end

function get_config_from_os(handle::Ptr{Cvoid})
    baud = ccall((:sp_get_config_baudrate, libserialport),
                 Cint, (Ptr{Cvoid},), handle)

    parity = ccall((:sp_get_config_parity, libserialport),
                   Cint, (Ptr{Cvoid},), handle)

    bits = ccall((:sp_get_config_bits, libserialport),
                 Cint, (Ptr{Cvoid},), handle)

    stop = ccall((:sp_get_config_stopbits, libserialport),
                 Cint, (Ptr{Cvoid},), handle)

    flow = ccall((:sp_get_config_flowcontrol, libserialport),
                 Cint, (Ptr{Cvoid},), handle)

    return PortConfig(
        baudrate = baud,
        parity = Parity(parity),
        databits = bits,
        stopbits = StopBits(stop),
        flowcontrol = FlowControl(flow)
    )
end

function apply_config_to_os!(handle::Ptr{Cvoid}, cfg::PortConfig)
    cfg_ref = Ref{Ptr{Cvoid}}(C_NULL)

    err = ccall((:sp_new_config, libserialport), Cint,
                (Ref{Ptr{Cvoid}},), cfg_ref)
    err < 0 && throw(SerialError(err, :sp_new_config))

    cfg_ptr = cfg_ref[]

    try
        check = ccall((:sp_set_config_baudrate, libserialport), Cint,
                      (Ptr{Cvoid}, Cint), cfg_ptr, cfg.baudrate)
        check < 0 && throw(SerialError(check, :sp_set_config_baudrate))

        check = ccall((:sp_set_config_parity, libserialport), Cint,
                      (Ptr{Cvoid}, Cint), cfg_ptr, cfg.parity)
        check < 0 && throw(SerialError(check, :sp_set_config_parity))

        check = ccall((:sp_set_config_bits, libserialport), Cint,
                      (Ptr{Cvoid}, Cint), cfg_ptr, cfg.databits)
        check < 0 && throw(SerialError(check, :sp_set_config_bits))

        check = ccall((:sp_set_config_stopbits, libserialport), Cint,
                      (Ptr{Cvoid}, Cint), cfg_ptr, cfg.stopbits)
        check < 0 && throw(SerialError(check, :sp_set_config_stopbits))

        check = ccall((:sp_set_config_flowcontrol, libserialport), Cint,
                      (Ptr{Cvoid}, Cint), cfg_ptr, cfg.flowcontrol)
        check < 0 && throw(SerialError(check, :sp_set_config_flowcontrol))

        check = ccall((:sp_set_config, libserialport), Cint,
                      (Ptr{Cvoid}, Ptr{Cvoid}), handle, cfg_ptr)
        check < 0 && throw(SerialError(check, :sp_set_config))

    finally
        ccall((:sp_free_config, libserialport), Cvoid,
              (Ptr{Cvoid},), cfg_ptr)
    end

    return nothing
end

# =========================
# Public API: configuration
# =========================

function change_configuration!(port::SerialPort, new_config::PortConfig)
    apply_config_to_os!(port.state.handle, new_config)
    port.state.config = new_config
    return port
end

getconfig(port::SerialPort) = port.state.config
info(port::SerialPort) = port.info

# =========================
# Public API: open/close
# =========================

function close(port::SerialPort)
    h = port.state.handle
    h == C_NULL && return

    ccall((:sp_close, libserialport), Cvoid, (Ptr{Cvoid},), h)
    ccall((:sp_free_port, libserialport), Cvoid, (Ptr{Cvoid},), h)

    port.state.handle = C_NULL
    return nothing
end

# =========================
# Public API: listing ports
# =========================

function list_ports()
    ports_ref = Ref{Ptr{Ptr{Cvoid}}}(C_NULL)

    err = ccall((:sp_list_ports, libserialport), Cint,
                (Ref{Ptr{Ptr{Cvoid}}},), ports_ref)
    err < 0 && throw(SerialError(err, :sp_list_ports))

    ports = ports_ref[]
    result = SerialPortInfo[]

    i = 1
    while true
        port = unsafe_load(ports, i)
        port == C_NULL && break

        name = unsafe_string(ccall((:sp_get_port_name, libserialport),
                                   Cstring, (Ptr{Cvoid},), port))

        desc_ptr = ccall((:sp_get_port_description, libserialport),
                         Cstring, (Ptr{Cvoid},), port)
        description = desc_ptr == C_NULL ? "" : unsafe_string(desc_ptr)

        transport_code = ccall((:sp_get_port_transport, libserialport),
                               Cint, (Ptr{Cvoid},), port)

        transport = transport_code == 0 ? :native :
                    transport_code == 1 ? :usb :
                    transport_code == 2 ? :bluetooth :
                    :unknown

        push!(result, SerialPortInfo(name, description, transport))
        i += 1
    end

    ccall((:sp_free_port_list, libserialport), Cvoid,
          (Ptr{Ptr{Cvoid}},), ports)

    return result
end

# =========================
# Public API: read / write core
# =========================

"""
    read_unsafe!(buffer, port; timeout_ms=0)

Reads into `buffer` (an AbstractArray{T}) and returns `(whole, partial)`:

- `whole`   = number of full elements of `T` read
- `partial` = number of leftover bytes

Partial bytes are not interpreted as elements.
"""
function read_unsafe!(buffer::AbstractArray{T}, port::SerialPort; timeout_ms::Integer=0) where T
    byte_capacity = sizeof(T) * length(buffer)

    nbytes = ccall((:sp_blocking_read, libserialport), Cint,
                   (Ptr{Cvoid}, Ptr{UInt8}, Cint, Cint),
                   port.state.handle, buffer, byte_capacity, timeout_ms)

    nbytes < 0 && throw(SerialError(nbytes, :sp_blocking_read))

    whole   = nbytes ÷ sizeof(T)
    partial = nbytes % sizeof(T)

    return whole, partial
end

"""
    read!(buffer, port; timeout_ms=0)

Reads into `buffer` and requires that the number of bytes read is an exact
multiple of `sizeof(T)`. Throws `PartialReadError` otherwise.

Returns the number of elements read.
"""
function read!(buffer::AbstractArray{T}, port::SerialPort; timeout_ms::Integer=0) where T
    whole, partial = read_unsafe!(buffer, port; timeout_ms=timeout_ms)

    if partial != 0
        throw(PartialReadError(whole, partial))
    end

    return whole
end

"""
    read(port; maxbytes=4096, timeout_ms=0)

Allocating read that returns a `Vector{UInt8}`.
"""
function read(port::SerialPort; maxbytes::Integer=4096, timeout_ms::Integer=0)
    buf = Vector{UInt8}(undef, maxbytes)

    nbytes = ccall((:sp_blocking_read, libserialport), Cint,
                   (Ptr{Cvoid}, Ptr{UInt8}, Cint, Cint),
                   port.state.handle, buf, maxbytes, timeout_ms)

    nbytes < 0 && throw(SerialError(nbytes, :sp_blocking_read))

    return buf[1:nbytes]
end

"""
    write(port, data; timeout_ms=0)

Blocking write. `data` can be `Vector{UInt8}` or `AbstractString`.
"""
function write(port::SerialPort, data::Vector{UInt8}; timeout_ms::Integer=0)
    n = ccall((:sp_blocking_write, libserialport), Cint,
              (Ptr{Cvoid}, Ptr{UInt8}, Cint, Cint),
              port.state.handle, data, length(data), timeout_ms)

    n < 0 && throw(SerialError(n, :sp_blocking_write))
    return n
end

function write(port::SerialPort, s::AbstractString; timeout_ms::Integer=0)
    data = Vector{UInt8}(codeunits(s))
    return write(port, data; timeout_ms=timeout_ms)
end

# =========================
# Public API: readline! (buffered)
# =========================

"""
    readline!(buffer, port; delimiter=UInt8('\\n'), timeout_ms=0)

Reads bytes into `buffer` until `delimiter` is found, the buffer is full,
or no more data is available. Returns the number of bytes written.
"""
function readline!(buffer::AbstractVector{UInt8}, port::SerialPort;
                   delimiter::UInt8 = UInt8('\n'),
                   timeout_ms::Integer = 0)

    count = 0

    while count < length(buffer)
        # Read exactly one byte into a 1-element view
        whole, partial = read_unsafe!(view(buffer, count+1:count+1), port;
                                      timeout_ms=timeout_ms)

        # No data
        if whole == 0 && partial == 0
            break
        end

        count += 1

        # Stop at delimiter
        if buffer[count] == delimiter
            break
        end
    end

    return count
end

# =========================
# Public API: streaming iterator (eachread)
# =========================

mutable struct SerialChunkStream{T, A<:AbstractArray{T}}
    port::SerialPort
    buffer::A
    timeout_ms::Int
    chunk_index::Int
end

"""
    eachread(port, buffer; timeout_ms=0)

Returns an iterator that repeatedly fills `buffer` and yields views of the
valid portion of each chunk.
"""
function eachread(port::SerialPort, buffer::AbstractArray{T};
                  timeout_ms::Integer = 0) where T
    return SerialChunkStream{T, typeof(buffer)}(port, buffer, timeout_ms, 0)
end

function Base.iterate(stream::SerialChunkStream)
    return _next_chunk(stream)
end

function Base.iterate(stream::SerialChunkStream, state)
    return _next_chunk(stream)
end

function _next_chunk(stream::SerialChunkStream{T}) where T
    buf = stream.buffer
    whole, partial = read_unsafe!(buf, stream.port; timeout_ms=stream.timeout_ms)

    # End of stream
    if whole == 0 && partial == 0
        return nothing
    end

    stream.chunk_index += 1

    # Return a view of the valid portion
    return view(buf, 1:whole), stream.chunk_index
end

end # module
