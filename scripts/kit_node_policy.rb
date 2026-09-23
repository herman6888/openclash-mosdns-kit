# openclash-mosdns-kit — 节点域名直通策略（v3）
# 用法: ruby kit_node_policy.rb <clash_config.yaml> [domains_direct_txt]
#
# 做三件事：
#  1) clash dns.nameserver-policy：节点 server 域名 → 国内 DNS 直连解析
#  2) clash dns.fake-ip-filter：节点域名 + *.节点域名 放行真实 IP
#     （假地址会被 OpenClash 自己劫持回代理口 → 死循环，节点全挂）
#  3) 生成 mosdns 直通名单 domains.direct.txt（ECH 基础设施 + 节点域名）
#
# 为什么 ECH 基础设施必须直通：
#  vless+ECH 节点握手前必须先拉 cloudflare-ech.com 的 HTTPS(TYPE65) RR
#  （ech= 配置）。这类查询若走 mosdns 的"非 CN 答案即丢弃"逻辑会被丢掉，
#  境外兜底线路一抖 → ECH 配置拿不到 → 全部 ECH 节点握手失败。
#  223.5.5.5 / 119.29.29.29 实测透传 HTTPS RR。

require "yaml"

cfg_path = ARGV[0]
abort "usage: kit_node_policy.rb <config.yaml> [domains.txt]" unless cfg_path

ECH_HOSTS = %w[
  cloudflare-ech.com
  ech.cloudflare.com
  cloudflare-dns.com
  dns.google
].freeze

DOM = /\A[a-zA-Z0-9][a-zA-Z0-9_-]*(\.[a-zA-Z0-9_-]+)+\z/

c = YAML.load_file(cfg_path)
dns = (c["dns"] ||= {})
pol = dns["nameserver-policy"] || {}
flt = dns["fake-ip-filter"] || []

hosts = ECH_HOSTS.dup

add = lambda do |arr|
  arr.each do |p|
    next unless p.is_a?(Hash)
    s = p["server"].to_s
    next if s.empty? || s =~ /\A[0-9.]+\z/
    next unless s =~ DOM
    pol[s] = "udp://223.5.5.5:53" unless pol.key?(s)
    hosts << s
    pat = "*." + s
    flt << pat unless flt.include?(pat)
  end
end

add.call(c["proxies"] || [])
(c["proxy-providers"] || {}).each do |_k, v|
  next unless v.is_a?(Hash) && v["path"]
  fp = v["path"].to_s
  fp = File.join("/etc/openclash", fp) unless fp.start_with?("/")
  if File.exist?(fp)
    begin
      add.call(YAML.load_file(fp)["proxies"] || [])
    rescue => e
      warn "provider parse skip: #{fp} #{e.message}"
    end
  end
end

dns["nameserver-policy"] = pol
dns["fake-ip-filter"] = flt
File.open(cfg_path, "w") { |f| f.write(c.to_yaml) }

domains_out = ARGV[1] || "/etc/mosdns/domains.direct.txt"
begin
  File.write(domains_out, hosts.uniq.join("\n") + "\n")
rescue => e
  warn "domains.direct.txt write skip: #{e.message}"
end

puts "node policy: #{pol.size} entries, fake-ip-filter: #{flt.size}, direct hosts: #{hosts.uniq.size}"
