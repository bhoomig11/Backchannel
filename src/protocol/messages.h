#ifndef BACKCHANNEL_MESSAGES_H
#define BACKCHANNEL_MESSAGES_H

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace backchannel::store {

struct Request {
    enum class Operation : std::uint16_t {
        append = 0,
        get = 1,
    };

    std::uint16_t client_id;
    std::uint16_t seq_no;
    Operation op;
    std::uint16_t channel_id;
    std::string message;
};

struct Response {
    enum class Status : std::uint16_t {
        ok = 0,
        not_found = 1,
        too_large = 2,
        not_leader = 3,
        wrong_group = 4,
    };

    std::uint16_t client_id;
    std::uint16_t seq_no;
    Status status;
    std::uint16_t server_id;
    std::optional<std::uint16_t> hint;
    std::vector<std::string> message_history;
};

} // namespace backchannel::store

#endif // BACKCHANNEL_MESSAGES_H
