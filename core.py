import cv2 as c, numpy as n, sys as s

M = {(22, 27, 34): 0, (14, 68, 41): 1, (0, 109, 50): 2, (38, 166, 65): 3, (57, 211, 83): 4}

def _x1(r):
    if r.size == 0: return 0
    p = r.reshape(-1, 3)
    v = [x for x in p if sum(x) > 40]
    if not v: return 0
    v = n.array(v)
    b, g, r = n.median(v[:, 0]), n.median(v[:, 1]), n.median(v[:, 2])
    m = float('inf'); l = 0
    for (t0, t1, t2), k in M.items():
        d = (r - t0)**2 + (g - t1)**2 + (b - t2)**2
        if d < m: m = d; l = k
    return l

def _x2(o, t=10):
    b = [c.boundingRect(x) + (x,) for x in o]
    b.sort(key=lambda k: k[0])
    cl = []; cc = []
    if b:
        cc.append(b[0])
        for i in range(1, len(b)):
            if abs(b[i][0] - cc[-1][0]) < t: cc.append(b[i])
            else: cl.append(cc); cc = [b[i]]
        cl.append(cc)
    r = []
    for l in cl:
        l.sort(key=lambda k: k[1])
        r.extend(l)
    return r

def run(p):
    i = c.imread(p)
    if i is None: return
    h = c.cvtColor(i, c.COLOR_BGR2HSV)
    m1 = c.inRange(h, n.array([35, 20, 20]), n.array([90, 255, 255]))
    m2 = c.inRange(h, n.array([0, 0, 18]), n.array([180, 50, 45]))
    mx = c.bitwise_or(m1, m2)
    ct, _ = c.findContours(mx, c.RETR_EXTERNAL, c.CHAIN_APPROX_SIMPLE)
    q = []
    for x in ct:
        a = c.contourArea(x); _, _, w, h_ = c.boundingRect(x)
        if 50 < a < 2000 and 0.8 < float(w)/h_ < 1.2: q.append(x)
    if not q: return
    s_bx = _x2(q)
    bs = ""
    for x, y, w, h_, _ in s_bx:
        mg = int(w * 0.25)
        roi = i[y+mg : y+h_-mg, x+mg : x+w-mg]
        lvl = _x1(roi)
        if lvl > 0: bs += format(lvl - 1, '02b')
    o = ""
    for j in range(0, len(bs), 8):
        bt = bs[j:j+8]
        if len(bt) == 8:
            cd = int(bt, 2)
            if cd > 0: o += chr(cd)
    print(o)

if __name__ == "__main__":
    run(s.argv[1] if len(s.argv) > 1 else "graph.png")
