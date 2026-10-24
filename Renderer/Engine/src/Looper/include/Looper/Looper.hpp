// Clean-room implementation from the WallpaperMachine spec e7-small-units.md; written without access to the original source.
#pragma once
#include <memory>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <mutex>
#include <condition_variable>
#include <string>
#include <thread>
#include <list>
#include <map>
#include <string_view>
#include <variant>
#include <array>

#include "Core/Visitors.hpp"
#include "Core/NoCopyMove.hpp"

namespace wallpaper
{
namespace looper
{

enum class status_t
{
    OK                = 0,
    INVALID_OPERATION = -ENOSYS,
    NOT_FOUND         = -ENOENT
};
using handler_id = int32_t;
class Handler;
class Message;

class Looper : NoCopy, public std::enable_shared_from_this<Looper> {
public:
    Looper();
    ~Looper();

    handler_id             registerHandler(const std::shared_ptr<Handler>&);
    void                   unregisterHandler(handler_id id);
    status_t               start();
    void                   stop();
    void                   post(const std::shared_ptr<Message>&);
    const std::string_view name() const;
    void                   setName(std::string_view);
    /// The log scope the looper's thread adopts when it starts; see
    /// `SetWallpaperLogScope`. Takes effect on the next `start()`.
    void                   setLogScope(uint64_t scope);

private:
    // Queue, running mark and thread live in a state the worker thread shares with
    // the looper, so a waiting thread never keeps the looper itself alive.
    struct Shared;

    // Whether the message may still be delivered by this looper, and delivery.
    void deliver(const std::shared_ptr<Message>&);

    std::shared_ptr<Shared> m_shared;
    std::string             m_name { "unknown" };
    uint64_t                m_log_scope { 0 };
};

class Handler : NoCopy, public std::enable_shared_from_this<Handler> {
public:
    const static handler_id INVALID_HANDLER_ID = 0;
    Handler();
    virtual ~Handler() = default;

    handler_id            id() const;
    std::weak_ptr<Looper> getLooper() const;

protected:
    virtual void onMessageReceived(const std::shared_ptr<Message>&) = 0;

private:
    friend class Looper;
    friend class Message;

    // One registration as seen at a single moment: identifier and looper read together.
    struct Binding {
        handler_id            id { INVALID_HANDLER_ID };
        std::weak_ptr<Looper> looper;
    };
    Binding binding() const;

    bool setID(handler_id id, std::weak_ptr<Looper> looper);
    // Unbinds the handler again when it still carries `id`, so it may be registered anew.
    void clearID(handler_id id);
    // Whether the handler is bound to exactly this looper under exactly this id.
    bool isBoundTo(const Looper* looper, handler_id id) const;

    // Identifier and looper change together, under this lock.
    mutable std::mutex      m_bind_mutex;
    std::atomic<handler_id> m_id;
    std::weak_ptr<Looper>   m_looper;
};

class Message : public std::enable_shared_from_this<Message> {
private:
    Message();
    Message(uint32_t what, const std::shared_ptr<Handler>&);
    friend class Looper;

public:
    static std::shared_ptr<Message> create();
    static std::shared_ptr<Message> create(uint32_t what, const std::shared_ptr<Handler>&);
    uint32_t                        what() const;
    void                            setTarget(const std::shared_ptr<Handler>&);
    void                            setWhat(uint32_t);
    status_t                        post();

    // Stores a value under `name`, replacing whatever was there. True on success.
    bool setBool(std::string_view, bool);
    bool setInt32(std::string_view, int32_t);
    bool setFloat(std::string_view, float);
    bool setString(std::string_view, std::string);
    bool setObject(std::string_view, const std::shared_ptr<void>&);

    // Reads a value back. True, with `*out` written, only when `name` holds a
    // value of exactly that type; otherwise false and `*out` is left alone.
    bool findBool(std::string_view name, bool* out) const;
    bool findInt32(std::string_view name, int32_t* out) const;
    bool findFloat(std::string_view name, float* out) const;
    bool findString(std::string_view name, std::string* out) const;

    // The object stored under `name`, as a `T` pointer: `T` has to be the type the
    // pointer had when it was stored.
    template<typename T>
    bool findObject(std::string_view name, std::shared_ptr<T>* value) const {
        if (value == nullptr) return false;
        const std::shared_ptr<void>* stored = findStoredObject(name);
        if (stored == nullptr) return false;
        *value = std::static_pointer_cast<T>(*stored);
        return true;
    }

private:
    using Value = std::variant<bool, int32_t, float, std::string, std::shared_ptr<void>>;

    const std::shared_ptr<void>* findStoredObject(std::string_view name) const;
    template<typename T>
    bool findValue(std::string_view name, T* out) const;

    // Where the message goes: the handler and the registration it had when it was
    // addressed. A default record addresses nobody.
    struct Route {
        std::weak_ptr<Handler> to;
        Handler::Binding       at;
    };

    uint32_t                        m_what { 0 };
    Route                           m_route;
    std::map<std::string, Value, std::less<>> m_values;
};

} // namespace looper
} // namespace wallpaper
