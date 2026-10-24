// Clean-room implementation from the WallpaperMachine spec e7-small-units.md; written without access to the original source.
#include "Looper.hpp"

#include <algorithm>
#include <deque>
#include <limits>
#include <system_error>

#ifdef __APPLE__
#    include <pthread.h>
#endif

#include "Utils/Logging.h"

using namespace wallpaper::looper;

namespace
{
// An identifier no other registration of this process has, never 0.
handler_id NextHandlerId() {
    static std::atomic<uint32_t> counter { 0 };
    const uint32_t               n = counter.fetch_add(1, std::memory_order_relaxed);
    return static_cast<handler_id>(n % static_cast<uint32_t>(std::numeric_limits<handler_id>::max())) + 1;
}

void NameCurrentThread(const std::string& name) {
#ifdef __APPLE__
    // The platform keeps 63 bytes and a longer name makes the call fail.
    pthread_setname_np(name.substr(0, 63).c_str());
#else
    (void)name;
#endif
}
} // namespace

struct Looper::Shared {
    std::mutex                             mutex;
    std::condition_variable                wake;
    std::deque<std::shared_ptr<Message>>   queue;
    std::map<handler_id, std::weak_ptr<Handler>> handlers;
    bool                                   running { false };
    uint64_t                               generation { 0 };
    std::thread                            thread;
};

Looper::Looper(): m_shared(std::make_shared<Shared>()) {}

Looper::~Looper() { stop(); }

void Looper::setName(std::string_view name) {
    std::lock_guard lock(m_shared->mutex);
    m_name = std::string(name);
}

void Looper::setLogScope(uint64_t scope) { m_log_scope = scope; }

const std::string_view Looper::name() const { return m_name; }

status_t Looper::start() {
    std::lock_guard lock(m_shared->mutex);
    if (m_shared->running) return status_t::INVALID_OPERATION;

    const uint64_t generation = ++m_shared->generation;
    m_shared->running         = true;
    try {
        m_shared->thread = std::thread(
            [shared = m_shared, owner = weak_from_this(), name = m_name, scope = m_log_scope, generation] {
                SetWallpaperLogScope(scope);
                NameCurrentThread(name);
                if (owner.expired()) {
                    LOG_ERROR("looper \"%s\" lost its owner before its thread began", name.c_str());
                    return;
                }
                LOG_INFO("looper \"%s\" started", name.c_str());
                for (;;) {
                    std::shared_ptr<Message> message;
                    {
                        std::unique_lock lk(shared->mutex);
                        shared->wake.wait(lk, [&] {
                            return ! shared->running || shared->generation != generation ||
                                   ! shared->queue.empty();
                        });
                        if (! shared->running || shared->generation != generation) break;
                        message = std::move(shared->queue.front());
                        shared->queue.pop_front();
                    }
                    // Held for this one delivery only: when the handler lets go of the
                    // last other owner, the looper ends here, on its own thread.
                    const std::shared_ptr<Looper> self = owner.lock();
                    if (! self) break;
                    self->deliver(message);
                }
                LOG_INFO("looper \"%s\" stopped", name.c_str());
            });
    } catch (const std::system_error& e) {
        m_shared->running = false;
        LOG_ERROR("looper \"%s\" can't start its thread: %s", m_name.c_str(), e.what());
        return status_t::INVALID_OPERATION;
    }
    return status_t::OK;
}

void Looper::stop() {
    std::thread worker;
    {
        std::lock_guard lock(m_shared->mutex);
        if (! m_shared->running) return;
        m_shared->running = false;
        worker            = std::move(m_shared->thread);
    }
    m_shared->wake.notify_all();
    if (! worker.joinable()) return;
    if (worker.get_id() == std::this_thread::get_id()) {
        // A handler is taking down its own looper: the thread finishes the message
        // it is in and leaves.
        LOG_INFO("looper \"%s\" stopped from its own thread, detaching it", m_name.c_str());
        worker.detach();
    } else {
        worker.join();
    }
}

void Looper::post(const std::shared_ptr<Message>& msg) {
    if (! msg) return;
    {
        std::lock_guard lock(m_shared->mutex);
        m_shared->queue.push_back(msg);
    }
    m_shared->wake.notify_one();
}

void Looper::deliver(const std::shared_ptr<Message>& msg) {
    const std::shared_ptr<Handler> handler = msg->m_route.to.lock();
    // Only a handler that still exists and is still registered here hears it.
    if (! handler || ! handler->isBoundTo(this, msg->m_route.at.id)) return;
    handler->onMessageReceived(msg);
}

handler_id Looper::registerHandler(const std::shared_ptr<Handler>& handler) {
    if (! handler) return Handler::INVALID_HANDLER_ID;
    std::weak_ptr<Looper> self = weak_from_this();
    if (self.expired()) {
        LOG_ERROR("a looper that nobody owns can't register handlers");
        return Handler::INVALID_HANDLER_ID;
    }
    const handler_id id = NextHandlerId();
    std::lock_guard  lock(m_shared->mutex);
    if (! handler->setID(id, self)) return Handler::INVALID_HANDLER_ID;
    m_shared->handlers[id] = handler;
    return id;
}

void Looper::unregisterHandler(handler_id id) {
    std::weak_ptr<Handler> entry;
    {
        std::lock_guard lock(m_shared->mutex);
        const auto      it = m_shared->handlers.find(id);
        if (it == m_shared->handlers.end()) return;
        entry = std::move(it->second);
        m_shared->handlers.erase(it);
    }
    if (const auto handler = entry.lock()) handler->clearID(id);
}

Handler::Handler(): m_id(INVALID_HANDLER_ID) {}

int32_t Handler::id() const {
    std::lock_guard lock(m_bind_mutex);
    return m_id.load();
}
std::weak_ptr<Looper> Handler::getLooper() const {
    std::lock_guard lock(m_bind_mutex);
    return m_looper;
}

Handler::Binding Handler::binding() const {
    std::lock_guard lock(m_bind_mutex);
    return Binding { m_id.load(), m_looper };
}

bool Handler::setID(handler_id id, std::weak_ptr<Looper> looper) {
    std::lock_guard lock(m_bind_mutex);
    if (m_id.load() != INVALID_HANDLER_ID) return false;
    m_looper = std::move(looper);
    m_id.store(id);
    return true;
}

void Handler::clearID(handler_id id) {
    std::lock_guard lock(m_bind_mutex);
    handler_id      expected = id;
    if (m_id.compare_exchange_strong(expected, INVALID_HANDLER_ID)) m_looper.reset();
}

bool Handler::isBoundTo(const Looper* looper, handler_id id) const {
    std::lock_guard lock(m_bind_mutex);
    return id != INVALID_HANDLER_ID && m_id.load() == id && m_looper.lock().get() == looper;
}

Message::Message() {}
Message::Message(uint32_t what, const std::shared_ptr<Handler>& handler): m_what(what) {
    setTarget(handler);
}

uint32_t Message::what() const { return m_what; }

std::shared_ptr<Message> Message::create() { return std::shared_ptr<Message>(new Message()); }
std::shared_ptr<Message> Message::create(uint32_t what, const std::shared_ptr<Handler>& handler) {
    return std::shared_ptr<Message>(new Message(what, handler));
}

void Message::setTarget(const std::shared_ptr<Handler>& handler) {
    m_route = handler ? Route { handler, handler->binding() } : Route {};
}

void Message::setWhat(uint32_t what) { m_what = what; }

status_t Message::post() {
    // An address taken before the handler was registered leads nowhere.
    const auto looper = m_route.at.looper.lock();
    if (m_route.at.id == Handler::INVALID_HANDLER_ID || ! looper) return status_t::NOT_FOUND;
    looper->post(shared_from_this());
    return status_t::OK;
}

bool Message::setBool(std::string_view name, bool value) {
    m_values.insert_or_assign(std::string(name), Value(value));
    return true;
}

bool Message::setInt32(std::string_view name, int32_t value) {
    m_values.insert_or_assign(std::string(name), Value(value));
    return true;
}

bool Message::setFloat(std::string_view name, float value) {
    m_values.insert_or_assign(std::string(name), Value(value));
    return true;
}

bool Message::setString(std::string_view name, std::string value) {
    m_values.insert_or_assign(std::string(name), Value(std::move(value)));
    return true;
}

bool Message::setObject(std::string_view name, const std::shared_ptr<void>& value) {
    m_values.insert_or_assign(std::string(name), Value(value));
    return true;
}

// An entry answers only a query of exactly its own kind.
template<typename T>
bool Message::findValue(std::string_view name, T* out) const {
    if (out == nullptr) return false;
    const auto it = m_values.find(name);
    if (it == m_values.end()) return false;
    const T* held = std::get_if<T>(&it->second);
    if (held == nullptr) return false;
    *out = *held;
    return true;
}

bool Message::findBool(std::string_view name, bool* value) const { return findValue(name, value); }
bool Message::findInt32(std::string_view name, int32_t* value) const { return findValue(name, value); }
bool Message::findFloat(std::string_view name, float* value) const { return findValue(name, value); }
bool Message::findString(std::string_view name, std::string* value) const {
    return findValue(name, value);
}

const std::shared_ptr<void>* Message::findStoredObject(std::string_view name) const {
    const auto it = m_values.find(name);
    return it == m_values.end() ? nullptr : std::get_if<std::shared_ptr<void>>(&it->second);
}
